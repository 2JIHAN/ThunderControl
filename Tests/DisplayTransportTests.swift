import Foundation
import CryptoKit

func runDisplayTransportTests() -> Int {
  var failures = 0
  func verify(_ value: Bool) { if !value { failures += 1 } }
  func rejects(_ action: () throws -> Void) { do { try action(); failures += 1 } catch {} }
  for sameEpoch in [false, true] {
    for pending in [false, true] {
      for hasRun in [false, true] {
        for now in [0.0, 14.999, 15.0, 16.0, Double.infinity, Double.nan] {
          verify(displayStartPermitted(sameEpoch: sameEpoch, pending: pending, hasRun: hasRun, now: now, deadline: 15) ==
            (sameEpoch && pending && !hasRun && now.isFinite && now < 15))
        }
      }
    }
  }
  verify(!displayStartPermitted(sameEpoch: true, pending: true, hasRun: false, now: 0, deadline: .infinity))
  verify(!displayStartPermitted(sameEpoch: true, pending: true, hasRun: false, now: 0, deadline: .nan))
  let root = SymmetricKey(size: .bits256)
  let s = "00000000-0000-4000-8000-000000000001", r = "00000000-0000-4000-8000-000000000002"
  func cipher(_ forward: Bool = true) -> DisplayChannelCipher { DisplayChannelCipher(root: root, senderNonce: s, receiverNonce: r, senderToReceiver: forward) }
  do {
    let hello = try DisplayChannelCipher.hello(sending: true, nonce: s)
    verify(try DisplayChannelCipher.parseHello(hello, expectSender: true) == s)
    rejects { _ = try DisplayChannelCipher.parseHello(hello, expectSender: false) }
    var v5Hello=hello;v5Hello[4]=53;rejects{_ = try DisplayChannelCipher.parseHello(v5Hello,expectSender:true)}
    var oldHello=hello;oldHello[4]=50;rejects{_ = try DisplayChannelCipher.parseHello(oldHello,expectSender:true)}
    for n in 0..<hello.count { rejects { _ = try DisplayChannelCipher.parseHello(Data(hello.prefix(n)), expectSender: true) } }
    rejects { _ = try DisplayChannelCipher.parseHello(hello + Data([0]), expectSender: true) }
    rejects { _ = try DisplayChannelCipher.hello(sending: false, nonce: "not-a-uuid") }
    rejects { _ = try DisplayChannelCipher.parseHello(Data("{\"kind\":\"sender-hello-v5\"}".utf8), expectSender: true) }
    var tx = cipher(), rx = cipher()
    let payload = Data([1, 0, 0, 0, 10])
    let first = try tx.seal(payload)
    verify(try rx.open(first) == payload)
    rejects { _ = try rx.open(first) }
    verify(rx.sequence == 1)
    let second = try tx.seal(Data([0]))
    var fresh = cipher(); rejects { _ = try fresh.open(second) }
    verify(fresh.sequence == 0)
    verify(try rx.open(second) == Data([0]))
    for index in first.indices {
      var modified = first; modified[index] ^= 1; var receiver = cipher()
      rejects { _ = try receiver.open(modified) }; verify(receiver.sequence == 0)
    }
    for n in 0..<first.count { var receiver = cipher(); rejects { _ = try receiver.open(Data(first.prefix(n))) } }
    var reverse = cipher(false); rejects { _ = try reverse.open(first) }
    var wrongSession = DisplayChannelCipher(root: root, senderNonce: r, receiverNonce: s, senderToReceiver: true)
    rejects { _ = try wrongSession.open(first) }
    var wrongKey = DisplayChannelCipher(root: SymmetricKey(size: .bits256), senderNonce: s, receiverNonce: r, senderToReceiver: true)
    rejects { _ = try wrongKey.open(first) }
    rejects { _ = try tx.seal(Data()) }
    rejects { _ = try tx.seal(Data(repeating: 2, count: DisplayChannelCipher.maximumPayload + 1)) }
    let largest = Data(repeating: 2, count: DisplayChannelCipher.maximumPayload)
    var bigTX = cipher(), bigRX = cipher()
    verify(try bigRX.open(bigTX.seal(largest)) == largest)
    rejects { _ = try bigRX.open(Data(repeating: 0, count: DisplayChannelCipher.maximumFrame + 1)) }
    verify(DisplayChannelCipher.confirmation(sending: true) != DisplayChannelCipher.confirmation(sending: false))
    verify(DisplayChannelCipher.validPayload(payload))
    verify(!DisplayChannelCipher.validPayload(Data([1,0,0,0,0])))
    verify(!DisplayChannelCipher.validPayload(Data([1,0,0,1])))
    verify(!DisplayChannelCipher.validPayload(Data([0])))
    verify(!DisplayChannelCipher.validPayload(DisplayChannelCipher.confirmation(sending: true)))
    verify(!DisplayChannelCipher.validPayload(Data([2])))
    verify(DisplayChannelCipher.validPayload(Data(repeating: 2, count: 10)))
    verify(!DisplayChannelCipher.validPayload(Data(repeating: 2, count: DisplayChannelCipher.maximumPayload + 1)))
    let control = Data([4, 1, 0, 0])
    verify(!DisplayChannelCipher.validInputPayload(control))
    verify(!DisplayChannelCipher.validInputPayload(Data([4]))) // v3 rejects all legacy input.
    verify(!DisplayChannelCipher.validInputPayload(Data(repeating: 4, count: 4096)))
    verify(!DisplayChannelCipher.validInputPayload(Data(repeating: 4, count: 4097)))
    verify(!DisplayChannelCipher.validInputPayload(Data()))
    verify(!DisplayChannelCipher.validInputPayload(Data([0])))
    verify(!DisplayChannelCipher.validInputPayload(payload))
    verify(!DisplayChannelCipher.validInputPayload(Data(repeating: 2, count: 10)))
    verify(!DisplayChannelCipher.allowedPayload(control, fromSender: true))
    verify(!DisplayChannelCipher.allowedPayload(control, fromSender: false))
    verify(DisplayChannelCipher.allowedPayload(payload, fromSender: true))
    verify(!DisplayChannelCipher.allowedPayload(payload, fromSender: false))
    verify(!DisplayChannelCipher.allowedPayload(Data(repeating: 2, count: 10), fromSender: false))
    for role in [false, true] {
      verify(!DisplayChannelCipher.allowedPayload(Data([0]), fromSender: role))
      verify(!DisplayChannelCipher.allowedPayload(DisplayChannelCipher.confirmation(sending: role), fromSender: role))
    }
    var inputTX = cipher(false), inputRX = cipher(false), wrongInputDirection = cipher()
    let sealedInput = try inputTX.seal(control)
    verify(try inputRX.open(sealedInput) == control)
    rejects { _ = try inputRX.open(sealedInput) }
    rejects { _ = try wrongInputDirection.open(sealedInput) }
  } catch { failures += 1 }
  func integer(_ n: UInt64, bytes: Int = 8) -> Data { Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: n >> ($0*8)) }) }
  let video = Data(repeating: 2, count: 10)
  let stamped = Data([6])+integer(0)+integer(100)+integer(110)+integer(150)+video
  do {
    let header = try DisplayStreamFrameHeader(stamped)
    verify(header.sequence == 0 && header.capture == 100 && header.encodeStart == 110 && header.encodeEnd == 150)
    // Exact TDSP6 envelope bytes and decoder body remain unchanged.
    verify(stamped.count == 43 && stamped[0] == 6 && stamped[33] == 2)
    for n in 0..<stamped.count { rejects { _ = try DisplayStreamFrameHeader(Data(stamped.prefix(n))) } }
    func envelope(_ kind: UInt8, _ capture: UInt64, _ start: UInt64, _ end: UInt64, _ body: Data) -> Data {
      var packet = Data([kind]); packet.append(integer(0)); packet.append(integer(capture))
      packet.append(integer(start)); packet.append(integer(end)); packet.append(body); return packet
    }
    let invalidEnvelopes: [Data] = [
      envelope(5,100,110,150,video), envelope(6,0,110,150,video),
      envelope(6,200,100,150,video), envelope(6,100,151,150,video),
      envelope(6,1,2,30_000_002,video), envelope(6,100,110,150,Data(repeating: 3,count: 10))
    ]
    for invalid in invalidEnvelopes {
      rejects { _ = try DisplayStreamFrameHeader(invalid) }
      rejects { _ = try DisplayStreamFrame(invalid) }
      verify(!DisplayChannelCipher.validPayload(invalid))
    }
    let exactDuration = Data([6])+integer(UInt64.max)+integer(1)+integer(1)+integer(30_000_001)+video
    let durationHeader = try DisplayStreamFrameHeader(exactDuration)
    verify(durationHeader.sequence == UInt64.max && durationHeader.encodeEnd-durationHeader.capture == 30_000_000)
    let maxTimestamps = Data([6])+integer(120)+integer(UInt64.max)+integer(UInt64.max)+integer(UInt64.max)+video
    verify(try DisplayStreamFrameHeader(maxTimestamps).encodeEnd == UInt64.max)
    // Data slices may have a nonzero startIndex; header offsets remain relative.
    let padded = Data([255])+stamped
    let sliced = padded.dropFirst()
    verify(sliced.startIndex != 0)
    verify(try DisplayStreamFrameHeader(sliced).capture == 100)
    verify(try DisplayStreamFrame(sliced).video == video)
    var largest = stamped
    largest.append(Data(repeating: 0,count: DisplayChannelCipher.maximumPayload-stamped.count))
    verify(try DisplayStreamFrameHeader(largest).encodeEnd == 150)
    verify(DisplayChannelCipher.validPayload(largest))
    largest.append(0)
    rejects { _ = try DisplayStreamFrameHeader(largest) }
    rejects { _ = try DisplayStreamFrame(largest) }
    verify(!DisplayChannelCipher.validPayload(largest))
    let frame = try DisplayStreamFrame(stamped)
    verify(frame.capture == 100 && frame.encodeStart == 110 && frame.encodeEnd == 150 && frame.video == video)
    verify(DisplayChannelCipher.allowedPayload(stamped, fromSender: true))
    verify(!DisplayChannelCipher.allowedPayload(stamped, fromSender: false))
    for n in 0..<stamped.count { rejects { _ = try DisplayStreamFrame(Data(stamped.prefix(n))) } }
    rejects { _ = try DisplayStreamFrame(Data([6])+integer(0)+integer(200)+integer(100)+integer(150)+video) }
    rejects { _ = try DisplayStreamFrame(Data([6])+integer(0)+integer(1)+integer(2)+integer(30_000_002)+video) }
    let cursor = Data([7])+integer(0)+Data([1,0])+integer(500_000,bytes:4)+integer(1_000_000,bytes:4)
    let point = try DisplayCursorMetadata(cursor); verify(point.visible && point.x == 0.5 && point.y == 1)
    verify(DisplayChannelCipher.allowedPayload(cursor, fromSender: true))
    verify(!DisplayChannelCipher.allowedPayload(cursor, fromSender: false))
    for n in 0..<cursor.count {rejects {_ = try DisplayCursorMetadata(Data(cursor.prefix(n)))}}
    for index in [9,10] {var invalid=cursor;invalid[index]=255;rejects {_ = try DisplayCursorMetadata(invalid)}}
    rejects {_ = try DisplayCursorMetadata(cursor+Data([0]))}
    rejects {_ = try DisplayCursorMetadata(Data([7])+integer(0)+Data([1,0])+integer(1_000_001,bytes:4)+integer(0,bytes:4))}
  } catch {failures += 1}
  let local=UUID().uuidString,peer=UUID().uuidString,other=UUID().uuidString
  if let pair=LayoutDevicePair(localID:local,peerID:peer) {verify(displayPeerBindingMatches(expected:pair,local:local,peer:peer));verify(!displayPeerBindingMatches(expected:pair,local:local,peer:other));verify(!displayPeerBindingMatches(expected:pair,local:peer,peer:local));verify(!displayPeerBindingMatches(expected:pair,local:local,peer:"invalid"))}else{verify(false)}
  print("Display transport offline crypto/framing tests: \(failures == 0 ? "PASS" : "FAIL"); no sockets, Keychain, capture, or input")
  return failures
}
