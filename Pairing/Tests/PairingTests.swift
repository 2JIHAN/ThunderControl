import Foundation
import CryptoKit

enum FixtureError: Error { case timeout, aborted }
final class Queue {
    let condition = NSCondition()
    var values: [Data] = []
    func put(_ d: Data) { condition.lock(); values.append(d); condition.signal(); condition.unlock() }
    func get() throws -> Data {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(0.8)
        while values.isEmpty { if !condition.wait(until:deadline) { throw FixtureError.timeout } }
        return values.removeFirst()
    }
}
final class ResultBox {
    let lock = NSLock()
    var sender: Result<Data,Error>?, receiver: Result<Data,Error>?
    func set(_ value: Result<Data,Error>, sender side: Bool) {
        lock.lock(); defer { lock.unlock() }; if side { sender = value } else { receiver = value }
    }
}
func mutate(_ d: Data, _ fn: (inout [String:String]) -> Void) -> Data {
    guard var m = try? JSONDecoder().decode([String:String].self,from:d) else { return d }
    fn(&m); let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try! e.encode(m)
}
@main struct PairingTests {
    static func run(_ title: String, pin: String = "0427", expected: Bool = false,
                    senderFilter: @escaping (Data)->Data = { $0 },
                    receiverFilter: @escaping (Data)->Data = { $0 },
                    approve: @escaping (PINPairingRequest)throws->String = { _ in "0427" },
                    cancelled: Bool = false) {
        let a = Queue(), b = Queue(), group = DispatchGroup(), results = ResultBox(), session = UUID().uuidString
        for isSender in [true,false] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let transport = PINPairingTransport(send:{ d in
                    if isSender { b.put(senderFilter(d)) } else { a.put(receiverFilter(d)) }
                },receive:{ try (isSender ? a : b).get() },cancelled:{ cancelled })
                let result = Result { try performPINPairing(isSender:isSender,senderPIN:isSender ? pin : nil,
                    sessionID:session,localName:isSender ? "Sender" : "Receiver",transport:transport,
                    receiverApproval:approve).withUnsafeBytes { Data($0) } }
                results.set(result,sender:isSender)
            }
        }
        guard group.wait(timeout:.now()+5) == .success else { fatalError("HANG: \(title)") }
        if expected {
            guard case .success(let x)? = results.sender, case .success(let y)? = results.receiver,
                  x == y, x.count == 32 else { fatalError("FAIL: \(title)") }
        } else {
            guard case .failure? = results.sender, case .failure? = results.receiver else { fatalError("FAIL OPEN: \(title)") }
        }
        print("PASS \(title)")
    }
    static func main() {
        run("matching PIN and 32-byte shared key", expected:true)
        run("wrong PIN rejects on both sides", approve:{ _ in "1234" })
        run("receiver explicit decline", approve:{ _ in throw FixtureError.aborted })
        run("cancelled transport",cancelled:true)
        run("invalid ASCII PIN",pin:"１２３４")
        run("role flip",senderFilter:{ mutate($0) { if $0["kind"] == "hello" { $0["role"] = "receiver" } } })
        run("identity modification bound to key",senderFilter:{ mutate($0) { if $0["kind"] == "hello" { $0["name"] = "Mallory" } } })
        run("stale request replay",receiverFilter:{ mutate($0) { $0["request"] = "00000000-0000-0000-0000-000000000000" } })
        run("corrupt PAKE share",senderFilter:{ mutate($0) { if $0["kind"] == "spake" { $0["payload"] = Data(repeating:0,count:32).base64EncodedString() } } })
        run("corrupt confirmation",senderFilter:{ mutate($0) { if $0["kind"] == "confirm" { $0["payload"] = Data(repeating:0,count:32).base64EncodedString() } } })
        run("4097-byte payload rejected",senderFilter:{ _ in Data(repeating:65,count:4097) })
        run("unknown JSON property",senderFilter:{ mutate($0) { $0["unexpected"] = "x" } })
        run("wrong JSON type",senderFilter:{ _ in Data("{\"v\":4}".utf8) })
        run("out-of-order stage",senderFilter:{ mutate($0) { $0["kind"] = "confirm" } })
        run("duplicate JSON keys",senderFilter:{ d in var bytes = d; bytes.removeLast(); bytes.append(Data(",\"v\":\"4\"}".utf8)); return bytes })
        print("All 15 bounded pairing fixtures passed.")
    }
}
