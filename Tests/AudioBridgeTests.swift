import Foundation

func runAudioBridgeTests() -> Int {
  var failures = 0
  func expect(_ ok: Bool, _ name: String) { if !ok { failures += 1; fputs("AudioBridge test failed: \(name)\n", stderr) } }
  let session = UUID().uuidString
  func packet(_ bytes: Int, sequence: UInt64 = 1) -> Wire {
    var w = Wire(kind: "audio", session: session, sequence: sequence); w.audio = Data(repeating: 1, count: bytes); return w
  }

  expect(AudioWirePolicy.validEnvelope(packet(1_920)), "10 ms packet accepted")
  expect(!AudioWirePolicy.validEnvelope(packet(1_922)), "partial frame rejected")
  expect(!AudioWirePolicy.validEnvelope(packet(AudioWirePolicy.maximumBytes + 4)), "oversized packet rejected")
  var extra = packet(1_920); extra.x = 0.5
  expect(!AudioWirePolicy.validEnvelope(extra), "extra field rejected")

  var off = PeerValidator(senderPeer: true, session: session)
  expect((try? off.accept(packet(1_920))) == nil, "audio rejected when not negotiated")
  var on = PeerValidator(senderPeer: true, session: session, audioSupported: true)
  expect((try? on.accept(packet(1_920))) != nil, "audio accepted when negotiated")
  var smuggled = Wire(kind: "ping", session: session, sequence: 2); smuggled.audio = Data(count: 4)
  expect((try? on.accept(smuggled)) == nil, "audio data on another kind rejected")

  var hello = Validator()
  expect((try? hello.accept(Wire(kind: "hello", session: session, sequence: 0, audioCodec: 1))) != nil, "hello advertises audio")
  var badHello = Validator()
  expect((try? badHello.accept(Wire(kind: "hello", session: session, sequence: 0, audioCodec: 2))) == nil, "unknown audio codec rejected")

  let left = UnsafeMutablePointer<Float>.allocate(capacity: 9_000), right = UnsafeMutablePointer<Float>.allocate(capacity: 9_000)
  defer { left.deallocate(); right.deallocate() }
  func chunk(_ frames: Int, _ value: Int16) -> Data {
    var samples = [Int16](repeating: value.littleEndian, count: frames * 2)
    return samples.withUnsafeMutableBytes { Data($0) }
  }
  var buffer = AudioJitterBuffer()
  buffer.push(chunk(960, 16_384))
  buffer.pull(480, left, right)
  expect(left[0] == 0 && !buffer.playing, "silent until primed")
  buffer.push(chunk(960, 16_384))
  buffer.pull(480, left, right)
  expect(left[0] == 0.5 && right[479] == 0.5 && buffer.count == 1_440, "plays once primed")
  buffer.pull(2_000, left, right)
  expect(left[1_439] == 0.5 && left[1_440] == 0 && !buffer.playing, "underrun pads silence and re-primes")
  buffer.push(chunk(AudioJitterBuffer.ceiling + 480, 1))
  expect(buffer.count == AudioJitterBuffer.prime, "backlog above ceiling trimmed to prime")
  return failures
}
