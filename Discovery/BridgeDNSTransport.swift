import Foundation
import Darwin
import BridgeDNSShim

enum BridgeDNSRequest {
    case browse
    case register(name: String, port: UInt16)
    case resolve(name: String, type: String, domain: String)
    case address(host: String)
}
enum BridgeDNSEvent {
    case service(add: Bool, index: UInt32, name: String, type: String, domain: String)
    case resolved(index: UInt32, host: String, port: UInt16)
    case address(add: Bool, index: UInt32, ipv4: String, ttl: UInt32)
    case registered
    case failed(Int32)
}
protocol BridgeDNSTransport: AnyObject {
    func open(_ request: BridgeDNSRequest, index: UInt32,
              receive: @escaping (BridgeDNSEvent) -> Void) -> UUID?
    func close(_ id: UUID)
    func stop()
}

/// All DNSServiceRef use and destruction happens on this serial queue.
final class NativeBridgeDNSTransport: BridgeDNSTransport {
    private final class Operation {
        var ref: DNSServiceRef?
        var source: DispatchSourceRead?
        var active = true
        let receive: (BridgeDNSEvent) -> Void
        init(_ receive: @escaping (BridgeDNSEvent) -> Void) { self.receive = receive }
        func emit(_ event: BridgeDNSEvent) { if active { receive(event) } }
    }
    private let queue = DispatchQueue(label: "ThunderControl.bridge.dnssd")
    private var operations: [UUID: Operation] = [:]
    private var allocatedSources = 0 // Includes cancelled sources awaiting their cancel handler.
    private static func operation(_ pointer: UnsafeMutableRawPointer?) -> Operation? {
        pointer.map { Unmanaged<Operation>.fromOpaque($0).takeUnretainedValue() }
    }
    func open(_ request: BridgeDNSRequest, index: UInt32,
              receive: @escaping (BridgeDNSEvent) -> Void) -> UUID? {
        guard BridgeDiscoveryValidation.validInterface(index) else { return nil }
        return queue.sync {
            guard allocatedSources < 64 else { return nil }
            let op = Operation(receive)
            let context = Unmanaged.passUnretained(op).toOpaque()
            let error: DNSServiceErrorType
            switch request {
            case .browse:
                error = DNSServiceBrowse(&op.ref, 0, index, "_thunderctrl._tcp", "local.", { _, flags, i, e, n, t, d, c in
                    guard let op = NativeBridgeDNSTransport.operation(c) else { return }
                    guard e == 0, let n = n, let t = t, let d = d else { op.emit(.failed(e)); return }
                    op.emit(.service(add: flags & UInt32(kDNSServiceFlagsAdd) != 0,
                                     index: i, name: String(cString: n), type: String(cString: t), domain: String(cString: d)))
                }, context)
            case let .register(name, port):
                error = DNSServiceRegister(&op.ref, 0, index, name, "_thunderctrl._tcp", "local.", nil,
                                           port.bigEndian, 0, nil, { _, _, e, _, _, _, c in
                    NativeBridgeDNSTransport.operation(c)?.emit(e == 0 ? .registered : .failed(e))
                }, context)
            case let .resolve(name, type, domain):
                error = DNSServiceResolve(&op.ref, UInt32(kDNSServiceFlagsForceMulticast), index, name, type, domain, { _, _, i, e, _, host, port, _, _, c in
                    guard let op = NativeBridgeDNSTransport.operation(c) else { return }
                    guard e == 0, let host = host else { op.emit(.failed(e)); return }
                    op.emit(.resolved(index: i, host: String(cString: host), port: UInt16(bigEndian: port)))
                }, context)
            case let .address(host):
                error = DNSServiceGetAddrInfo(&op.ref, UInt32(kDNSServiceFlagsForceMulticast), index, UInt32(kDNSServiceProtocol_IPv4), host, { _, flags, i, e, _, address, ttl, c in
                    guard let op = NativeBridgeDNSTransport.operation(c) else { return }
                    guard e == 0, let address = address else { op.emit(.failed(e)); return }
                    guard address.pointee.sa_family == sa_family_t(AF_INET) else { return }
                    var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    guard inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return }
                    op.emit(.address(add: flags & UInt32(kDNSServiceFlagsAdd) != 0,
                                     index: i, ipv4: String(cString: buffer), ttl: ttl))
                }, context)
            }
            guard error == 0, let ref = op.ref else {
                if let ref = op.ref { DNSServiceRefDeallocate(ref) }
                return nil
            }
            let fd = DNSServiceRefSockFD(ref)
            guard fd >= 0 else { DNSServiceRefDeallocate(ref); return nil }
            let id = UUID()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            op.source = source
            source.setEventHandler { [weak op] in
                guard let op = op, op.active, let ref = op.ref else { return }
                let result = DNSServiceProcessResult(ref)
                if result != 0 { op.emit(.failed(result)) }
            }
            // The cancel handler retains the context until no read handler can run.
            // DNSServiceRefDeallocate closes the fd; never close it separately.
            source.setCancelHandler { [op, weak self] in
                if let ref = op.ref { DNSServiceRefDeallocate(ref); op.ref = nil }
                op.source = nil
                self?.allocatedSources -= 1
            }
            allocatedSources += 1
            operations[id] = op
            source.resume()
            return id
        }
    }
    func close(_ id: UUID) {
        queue.sync {
            guard let op = operations.removeValue(forKey: id) else { return }
            op.active = false
            op.source?.cancel()
        }
    }
    func stop() {
        queue.sync {
            for op in operations.values { op.active = false; op.source?.cancel() }
            operations.removeAll()
        }
    }
    deinit { stop() }
}
