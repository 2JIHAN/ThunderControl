// Integration (Swift 5, macOS 13+, arm64): compile BridgePeer.swift,
// BridgeDNSTransport.swift and this file with -I <Discovery>/DNSShim.
// module.modulemap imports the SDK dns_sd.h and links libdns_sd; no packages.
// Exclude Tests/ from the app target. Tests are a standalone @main executable.
// Caller must bind the receiver listener to the verified bridge IPv4/interface,
// keep verification current, and call stop on link loss or index/address changes.
// Index nonzero validation is not proof of Thunderbolt identity. Discovery never
// authenticates peers; require explicit user selection and a later PAKE handshake.
// A Bonjour service registration has no address-family option. Registration is
// interface-scoped; resolution uses IPv4-only GetAddrInfo and exposes only A
// endpoints. This does not disable IPv6 system-wide or suppress OS AAAA records.
// If both operations are required: startBrowsing(...), then advertise(...).
// stop() deliberately does not invoke onPeers; the caller clears its selection UI.

import Foundation

/// Caller must supply the currently verified bridge index, never a guessed/default index.
/// Discovery is untrusted. Show peers for explicit selection; authenticate via PAKE later.
@MainActor public final class BridgeDiscovery {
    private struct Entry {
        let token = UUID()
        let name: String
        let deadline: Date
        var resolve: UUID?
        var address: UUID?
        var port: UInt16 = 0
        var endpoints: [String: Date] = [:]
    }
    /// Static diagnostics only; no untrusted DNS payloads. Retained across stop/restart.
    public var onError: ((String) -> Void)?
    public var isBrowsing:Bool {browse != nil}
    public var isAdvertising:Bool {advertisement != nil}
    private var reportedErrors: Set<String> = []
    private func reportError(_ code: Int32) {
        let message = "Bonjour discovery failed (DNS-SD error \(code)). Check Local Network permission and the verified bridge connection."
        guard reportedErrors.count < 4, reportedErrors.insert(message).inserted else { return }
        onError?(message)
    }
    private let transport: BridgeDNSTransport

    private let useTimer: Bool
    private var generation: UInt64 = 0
    private var index: UInt32 = 0
    private var localIPv4 = ""
    private var browse: UUID?
    private var advertisement: UUID?
    private var entries: [String: Entry] = [:]
    private var onPeers: (([BridgePeer]) -> Void)?
    private var timer: Task<Void, Never>?

    public convenience init() { self.init(transport: NativeBridgeDNSTransport()) }
    init(transport: BridgeDNSTransport, useTimer: Bool = true) {
        self.transport = transport; self.useTimer = useTimer
    }
    /// Starts a fresh session, cancelling previous browse AND advertisement.
    /// To run both, call startBrowsing first, then advertise on the same index.
    public func startBrowsing(interfaceIndex: UInt32, localIPv4: String,
                             onPeers: @escaping ([BridgePeer]) -> Void) {
        stop()
        guard BridgeDiscoveryValidation.validInterface(interfaceIndex),
              let local = BridgeDiscoveryValidation.ipv4(localIPv4) else { return }
        index = interfaceIndex; self.localIPv4 = local; self.onPeers = onPeers
        let current = generation
        browse = transport.open(.browse, index: index) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == current, self.browse != nil else { return }
                self.browseEvent(event)
            }
        }
        guard browse != nil else { stop(); reportError(-65537); return }
        publish()
        if useTimer {
            timer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    guard let self = self, self.generation == current else { return }
                    self.expire(now: Date())
                }
            }
        }
    }
    /// Advertises an already-running receiver listener. Does not open/bind a listener.
    public func advertise(interfaceIndex: UInt32, name: String, port: UInt16) {
        guard BridgeDiscoveryValidation.validInterface(interfaceIndex), port != 0 else { stop(); return }
        if index != 0 && index != interfaceIndex { stop() }
        index = interfaceIndex
        if let id = advertisement { transport.close(id); advertisement = nil }
        let current = generation
        // Separate token prevents a delayed error from cancelling a replacement advertisement.
        let token = UUID(); advertisementToken = token
        advertisement = transport.open(.register(name: BridgeDiscoveryValidation.displayName(name), port: port), index: index) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == current, self.advertisementToken == token else { return }
                if case let .failed(code) = event, let id = self.advertisement {
                    self.transport.close(id); self.advertisement = nil; self.reportError(code)
                }
            }
        }
        if advertisement == nil { reportError(-65537) }
    }
    private var advertisementToken = UUID()
    /// Cancels all sources. Queued deliveries from any older session become inert.
    /// No onPeers callback, including an empty-list callback, occurs after stop.
    public func stop() {
        generation &+= 1; reportedErrors.removeAll()
        timer?.cancel(); timer = nil
        transport.stop()
        browse = nil; advertisement = nil; advertisementToken = UUID()
        entries.removeAll(); onPeers = nil; index = 0; localIPv4 = ""
    }
    private func browseEvent(_ event: BridgeDNSEvent) {
        switch event {
        case let .service(add, i, name, type, domain):
            guard i == index, type == "_thunderctrl._tcp.", domain.lowercased() == "local.",
                  !name.isEmpty, name.utf8.count <= 63 else { return }
            // Length-prefixed identity avoids delimiter collisions in arbitrary service names.
            let key = "\(i):\(name.utf8.count):\(name):\(type):\(domain.lowercased())"
            if !add { remove(key); publish(); return }
            guard entries[key] == nil, entries.count < BridgeDiscoveryValidation.maximumPeers else { return }
            let entry = Entry(name: BridgeDiscoveryValidation.displayName(name), deadline: Date().addingTimeInterval(10))
            entries[key] = entry
            let current = generation; let token = entry.token
            let id = transport.open(.resolve(name: name, type: type, domain: domain), index: index) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self = self, self.generation == current, self.entries[key]?.token == token else { return }
                    self.resolveEvent(event, key: key)
                }
            }
            entries[key]?.resolve = id
            if id == nil { remove(key) }
        case let .failed(code):
            // Fail closed, including dropping stale peer hints.
            for key in Array(entries.keys) { remove(key) }
            if let id = browse { transport.close(id) }; browse = nil
            let current = generation
            publish()
            if generation == current { reportError(code) }
        default: break
        }
    }
    private func resolveEvent(_ event: BridgeDNSEvent, key: String) {
        guard let entry = entries[key], entry.address == nil else { return }
        switch event {
        case let .resolved(i, host, port):
            guard i == index, port != 0, host.lowercased().hasSuffix(".local."), host.utf8.count <= 253 else { remove(key); publish(); return }
            if let id = entry.resolve { transport.close(id); entries[key]?.resolve = nil }
            entries[key]?.port = port
            let current = generation; let token = entry.token
            let id = transport.open(.address(host: host), index: index) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self = self, self.generation == current, self.entries[key]?.token == token else { return }
                    self.addressEvent(event, key: key)
                }
            }
            entries[key]?.address = id
            if id == nil { remove(key); publish() }
        case .failed: remove(key); publish()
        default: break
        }
    }
    private func addressEvent(_ event: BridgeDNSEvent, key: String) {
        switch event {
        case let .address(add, i, raw, ttl):
            guard i == index, let ip = BridgeDiscoveryValidation.ipv4(raw), ip != localIPv4 else { return }
            if add && ttl > 0 {
                // Bound address fanout too. DNS-SD peers may advertise many A records.
                guard entries[key]?.endpoints[ip] != nil || (entries[key]?.endpoints.count ?? 8) < 8 else { return }
                entries[key]?.endpoints[ip] = Date().addingTimeInterval(Double(min(ttl, 3600)))
            } else { entries[key]?.endpoints.removeValue(forKey: ip) }
            publish()
        case .failed: remove(key); publish()
        default: break
        }
    }
    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let id = entry.resolve { transport.close(id) }
        if let id = entry.address { transport.close(id) }
    }
    func expire(now: Date) {
        for key in Array(entries.keys) {
            guard let entry = entries[key] else { continue }
            if entry.address == nil && entry.deadline <= now { remove(key); continue }
            if entry.endpoints.isEmpty && entry.deadline <= now { remove(key); continue }
            entries[key]?.endpoints = entry.endpoints.filter { $0.value > now }
        }
        publish()
    }
    private func publish() {
        let now = Date()
        let peers = entries.compactMap { key, entry -> BridgePeer? in
            guard let ip = entry.endpoints.filter({ $0.value > now }).keys.sorted().first, entry.port != 0 else { return nil }
            return BridgePeer(id: key, name: entry.name, ipv4: ip, port: entry.port)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        onPeers?(peers)
    }
    deinit { timer?.cancel(); transport.stop() }
}
