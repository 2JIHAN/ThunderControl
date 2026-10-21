import Foundation
import CryptoKit
import CSPAKE2

/// Framing, deadlines, cancellation-unblocking and aggregate online-guess limits belong to caller.
struct PINPairingTransport {
    let send: (Data) throws -> Void
    let receive: () throws -> Data
    let cancelled: () -> Bool
}
struct PINPairingRequest {
    let sessionID: String
    let requestID: String
    let senderName: String
}
enum PINPairingError: Error, LocalizedError {
    case cancelled, invalidPIN, invalidMessage, authenticationFailed, cryptographyFailed
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Pairing cancelled."
        case .invalidPIN: return "Pairing requires exactly four ASCII digits."
        case .invalidMessage: return "Invalid or out-of-order pairing message."
        case .authenticationFailed: return "Pairing authentication failed."
        case .cryptographyFailed: return "Pairing cryptography failed."
        }
    }
}

/// Established BoringSSL SPAKE2, not independently audited here. One invocation is one attempt.
/// receiverApproval runs on this function's thread. Caller must present/dispatch approval on main.
func performPINPairing(isSender: Bool, senderPIN: String?, sessionID: String,
                       localName: String, transport: PINPairingTransport,
                       receiverApproval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
    let p = BoundedPINHandshake(isSender: isSender, session: sessionID, name: localName, io: transport)
    do { return try p.run(senderPIN: senderPIN, approval: receiverApproval) }
    catch {
        // No error details, names, passwords or secret state are sent or logged.
        // Caller must make send bounded too, including this best-effort abort.
        if !transport.cancelled(), let request = p.request {
            try? p.send("abort", role: isSender ? "sender" : "receiver", request: request)
        }
        throw error
    }
}

private final class BoundedPINHandshake {
    let isSender: Bool, session: String, name: String, io: PINPairingTransport
    var request: String?
    let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    let decoder = JSONDecoder()
    init(isSender: Bool, session: String, name: String, io: PINPairingTransport) {
        self.isSender = isSender; self.session = session; self.name = name; self.io = io
    }
    func check() throws { if io.cancelled() { throw PINPairingError.cancelled } }
    func validName(_ n: String) -> Bool {
        !n.isEmpty && n.utf8.count <= 128 && !n.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    func validPIN(_ pin: String) -> Bool { pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
    func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString == value }
    func encode(_ fields: [String:String]) throws -> Data { try encoder.encode(fields) }
    func send(_ kind: String, role: String, request: String, extra: [String:String] = [:]) throws {
        try check()
        var m = ["v":"4", "kind":kind, "role":role, "session":session, "request":request]
        for (k,v) in extra { m[k] = v }
        let bytes = try encode(m)
        guard bytes.count <= 4096 else { throw PINPairingError.invalidMessage }
        try io.send(bytes); try check()
    }
    func read(_ kind: String, role: String, request expected: String?, extras: Set<String>) throws -> [String:String] {
        try check(); let data = try io.receive(); try check()
        guard !data.isEmpty, data.count <= 4096,
              let m = try? decoder.decode([String:String].self, from:data),
              let canonical = try? encode(m), canonical == data,
              m["v"] == "4", m["session"] == session, m["role"] == role,
              let req = m["request"], canonicalUUID(req), expected == nil || req == expected
        else { throw PINPairingError.invalidMessage }
        if m["kind"] == "abort" {
            guard Set(m.keys) == Set(["v","kind","role","session","request"]) else { throw PINPairingError.invalidMessage }
            throw PINPairingError.authenticationFailed
        }
        guard m["kind"] == kind,
              Set(m.keys) == Set(["v","kind","role","session","request"]).union(extras)
        else { throw PINPairingError.invalidMessage }
        return m
    }
    func bytes(_ m: [String:String], _ field: String, count: Int) throws -> Data {
        guard let value = m[field], let b = Data(base64Encoded:value), b.count == count,
              b.base64EncodedString() == value else { throw PINPairingError.invalidMessage }
        return b
    }
    func randomNonce() -> String {
        SymmetricKey(size:.bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }
    func join(_ values: [Data]) -> Data {
        var out = Data()
        for v in values { var n = UInt32(v.count).bigEndian; withUnsafeBytes(of:&n) { out.append(contentsOf:$0) }; out.append(v) }
        return out
    }
    func derive(_ key: SymmetricKey, salt: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial:key, salt:salt,
            info:Data(("ThunderControl/pairing/v4/" + label).utf8), outputByteCount:32)
    }
    func run(senderPIN: String?, approval: (PINPairingRequest) throws -> String) throws -> SymmetricKey {
        try check()
        guard canonicalUUID(session), validName(name) else { throw PINPairingError.invalidMessage }
        let senderHello: [String:String], receiverHello: [String:String], pin: String
        if isSender {
            guard let supplied = senderPIN, validPIN(supplied) else { throw PINPairingError.invalidPIN }
            pin = supplied
            let req = UUID().uuidString; request = req
            let extra = ["name":name, "nonce":randomNonce()]
            try send("hello", role:"sender", request:req, extra:extra)
            senderHello = ["v":"4","kind":"hello","role":"sender","session":session,"request":req,"name":name,"nonce":extra["nonce"]!]
            receiverHello = try read("hello", role:"receiver", request:req, extras:["name","nonce"])
        } else {
            guard senderPIN == nil else { throw PINPairingError.invalidMessage }
            senderHello = try read("hello", role:"sender", request:nil, extras:["name","nonce"])
            guard let senderName = senderHello["name"], validName(senderName) else { throw PINPairingError.invalidMessage }
            _ = try bytes(senderHello,"nonce",count:32)
            let req = senderHello["request"]!; request = req
            // No outgoing PAKE message or authentication attempt until explicit acceptance.
            pin = try approval(PINPairingRequest(sessionID:session,requestID:req,senderName:senderName))
            try check(); guard validPIN(pin) else { throw PINPairingError.invalidPIN }
            let nonce = randomNonce()
            receiverHello = ["v":"4","kind":"hello","role":"receiver","session":session,"request":req,"name":name,"nonce":nonce]
            try send("hello", role:"receiver", request:req, extra:["name":name,"nonce":nonce])
        }
        guard validName(senderHello["name"]!), validName(receiverHello["name"]!) else { throw PINPairingError.invalidMessage }
        let sn = try bytes(senderHello,"nonce",count:32), rn = try bytes(receiverHello,"nonce",count:32)
        guard sn != rn else { throw PINPairingError.invalidMessage }
        let helloTranscript = join([Data("ThunderControl/pairing/v4".utf8), try encode(senderHello), try encode(receiverHello)])
        let binding = Data(SHA256.hash(data:helloTranscript))
        let senderIdentity = join([Data("Alice/sender".utf8),binding])
        let receiverIdentity = join([Data("Bob/receiver".utf8),binding])
        let mine = isSender ? senderIdentity : receiverIdentity, theirs = isSender ? receiverIdentity : senderIdentity
        let ctx = mine.withUnsafeBytes { a in theirs.withUnsafeBytes { b in
            SPAKE2_CTX_new(isSender ? spake2_role_alice : spake2_role_bob,
                          a.bindMemory(to:UInt8.self).baseAddress,mine.count,
                          b.bindMemory(to:UInt8.self).baseAddress,theirs.count)
        } }
        guard let context = ctx else { throw PINPairingError.cryptographyFailed }
        defer { SPAKE2_CTX_free(context) }
        var message = [UInt8](repeating:0,count:Int(SPAKE2_MAX_MSG_SIZE)), messageLen = 0
        let password = Data(pin.utf8)
        let generated = password.withUnsafeBytes { pw in SPAKE2_generate_msg(context,&message,&messageLen,message.count,pw.bindMemory(to:UInt8.self).baseAddress,password.count) }
        guard generated == 1, messageLen == 32 else { throw PINPairingError.cryptographyFailed }
        let myMessage = Data(message.prefix(messageLen)), req = request!
        let myRole = isSender ? "sender" : "receiver", otherRole = isSender ? "receiver" : "sender"
        // Sender writes first, receiver reads first: works on bounded synchronous transports.
        let peer: [String:String]
        if isSender {
            try send("spake",role:myRole,request:req,extra:["payload":myMessage.base64EncodedString()])
            peer = try read("spake",role:otherRole,request:req,extras:["payload"])
        } else {
            peer = try read("spake",role:otherRole,request:req,extras:["payload"])
            try send("spake",role:myRole,request:req,extra:["payload":myMessage.base64EncodedString()])
        }
        let peerMessage = try bytes(peer,"payload",count:32)
        var secret = [UInt8](repeating:0,count:Int(SPAKE2_MAX_KEY_SIZE)), secretLen = 0
        defer { for i in secret.indices { secret[i] = 0 } }
        let processed = peerMessage.withUnsafeBytes { b in SPAKE2_process_msg(context,&secret,&secretLen,secret.count,b.bindMemory(to:UInt8.self).baseAddress,peerMessage.count) }
        guard processed == 1, secretLen == 64 else { throw PINPairingError.authenticationFailed }
        let transcript = join([helloTranscript,isSender ? myMessage : peerMessage,isSender ? peerMessage : myMessage])
        let digest = Data(SHA256.hash(data:transcript)), base = SymmetricKey(data:secret)
        let senderConfirm = derive(base,salt:digest,label:"sender-confirm")
        let receiverConfirm = derive(base,salt:digest,label:"receiver-confirm")
        func tag(_ role: String, _ key: SymmetricKey) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for:join([Data(role.utf8),transcript]),using:key))
        }
        func verify(_ role: String, _ key: SymmetricKey) throws {
            let m = try read("confirm",role:role,request:req,extras:["payload"])
            let received = try bytes(m,"payload",count:32)
            guard HMAC<SHA256>.isValidAuthenticationCode(received,authenticating:join([Data(role.utf8),transcript]),using:key) else { throw PINPairingError.authenticationFailed }
        }
        if isSender {
            try send("confirm",role:myRole,request:req,extra:["payload":tag(myRole,senderConfirm).base64EncodedString()])
            try verify(otherRole,receiverConfirm)
        } else {
            try verify(otherRole,senderConfirm)
            try send("confirm",role:myRole,request:req,extra:["payload":tag(myRole,receiverConfirm).base64EncodedString()])
        }
        try check()
        return derive(base,salt:digest,label:"application-session-key")
    }
}
