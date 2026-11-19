import AVFoundation
import CoreAudio
import Foundation
import os

/// Wire format: one "audio" packet carries 48 kHz stereo signed 16-bit little-endian PCM, interleaved.
enum AudioWirePolicy {
  static let sampleRate = 48_000.0
  static let chunkFrames = 480 // 10 ms
  static let maximumBytes = 4 * 2_400 // 50 ms
  static func validEnvelope(_ w: Wire) -> Bool {
    guard w.kind == "audio", let pcm = w.audio, !pcm.isEmpty, pcm.count <= maximumBytes, pcm.count % 4 == 0,
      let data = try? JSONEncoder().encode(w),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    return Set(json.keys) == Set(["kind", "session", "sequence", "audio"])
  }
}

/// Jitter buffer for peer audio. Waits for `prime` frames before playing, and drops the
/// oldest frames above `ceiling` so latency cannot grow when the two Macs' clocks drift.
struct AudioJitterBuffer {
  static let prime = 1_920 // 40 ms
  static let ceiling = 7_200 // 150 ms
  private(set) var frames: [Int16] = [] // interleaved stereo
  private(set) var playing = false
  var count: Int { frames.count / 2 }
  mutating func push(_ pcm: Data) {
    pcm.withUnsafeBytes { raw in frames.append(contentsOf: raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }) }
    if count > Self.ceiling { frames.removeFirst((count - Self.prime) * 2) }
    if count >= Self.prime { playing = true }
  }
  /// Fills `left`/`right` with `n` frames; underrun returns silence and re-primes.
  mutating func pull(_ n: Int, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
    let available = playing ? min(n, count) : 0
    for i in 0..<available {
      left[i] = Float(frames[i * 2]) / 32_768
      right[i] = Float(frames[i * 2 + 1]) / 32_768
    }
    for i in available..<n { left[i] = 0; right[i] = 0 }
    frames.removeFirst(available * 2)
    if available < n { playing = false }
  }
}

/// While connected, shows the peer as an output device and moves audio in both directions:
/// sends what local apps play into the ThunderControl device, and plays what the peer sends.
@MainActor final class AudioBridge {
  static let deviceUID = "local.experimental.ThunderControl.Audio"
  static let driverBundleID = "local.experimental.ThunderControl.AudioDriver"
  private static let peerNameSelector = AudioObjectPropertySelector(0x7463_706E) // 'tcpn'

  private let send: (Data) -> Void
  private var captureDevice: AudioObjectID = 0
  private var captureProc: AudioDeviceIOProcID?
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private let playback = OSAllocatedUnfairLock(initialState: AudioJitterBuffer())
  private var engine: AVAudioEngine?
  private var idleTimer: Timer?
  private var configObserver: NSObjectProtocol?
  private var lastPacket = 0.0

  init(send: @escaping (Data) -> Void) { self.send = send }

  /// Returns false when the driver is not installed; audio then stays off for this session.
  @discardableResult func start(peerName: String) -> Bool {
    guard Self.setPeerName(peerName) else { return false }
    var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.followDefaultOutput() }
    }
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    defaultOutputListener = listener
    followDefaultOutput()
    return true
  }

  func stop() {
    if let listener = defaultOutputListener {
      var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
      defaultOutputListener = nil
    }
    stopCapture()
    stopPlayback()
    Self.setPeerName("")
  }

  /// Plays a packet from the peer. Never plays into our own device: that would loop
  /// the audio back to the peer when both Macs select each other.
  func receive(_ pcm: Data) {
    guard Self.defaultOutputUID() != Self.deviceUID else { return }
    playback.withLock { $0.push(pcm) }
    lastPacket = ProcessInfo.processInfo.systemUptime
    if engine == nil { startPlayback() }
  }

  // MARK: Capture

  /// Capture runs only while the ThunderControl device is the default output, so the
  /// microphone indicator is lit only while this Mac's audio is going to the peer.
  private func followDefaultOutput() {
    let device = Self.device(uid: Self.deviceUID)
    let selected = device != 0 && Self.defaultOutputUID() == Self.deviceUID
    if selected, captureProc == nil {
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { [weak self] in
          guard granted, let self, self.defaultOutputListener != nil else { return }
          self.startCapture(device)
        }
      }
    } else if !selected {
      stopCapture()
    }
  }

  private func startCapture(_ device: AudioObjectID) {
    guard captureProc == nil, device != 0 else { return }
    var proc: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, Self.captureBlock(send))
    guard status == noErr, let proc else { return }
    guard AudioDeviceStart(device, proc) == noErr else { AudioDeviceDestroyIOProcID(device, proc); return }
    captureDevice = device
    captureProc = proc
  }

  /// Runs on the HAL I/O thread, outside the main actor.
  private nonisolated static func captureBlock(_ send: @escaping (Data) -> Void) -> AudioDeviceIOBlock {
    var pending = [Int16]()
    pending.reserveCapacity(AudioWirePolicy.chunkFrames * 4)
    return { _, input, _, _, _ in
      let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
      guard let buffer = buffers.first, let data = buffer.mData else { return }
      let samples = data.assumingMemoryBound(to: Float.self)
      for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
        pending.append(Int16(max(-1, min(1, samples[i])) * 32_767))
      }
      let chunk = AudioWirePolicy.chunkFrames * 2
      while pending.count >= chunk {
        let slice = pending[0..<chunk]
        // Exact digital silence means nothing is playing; skip it rather than stream zeros.
        if slice.contains(where: { $0 != 0 }) {
          let pcm = slice.withUnsafeBytes { Data($0) }
          DispatchQueue.main.async { send(pcm) }
        }
        pending.removeFirst(chunk)
      }
    }
  }

  private func stopCapture() {
    guard let proc = captureProc else { return }
    AudioDeviceStop(captureDevice, proc)
    AudioDeviceDestroyIOProcID(captureDevice, proc)
    captureProc = nil
    captureDevice = 0
  }

  // MARK: Playback

  private func startPlayback() {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: AudioWirePolicy.sampleRate, channels: 2)!
    let source = AVAudioSourceNode(format: format, renderBlock: Self.renderBlock(playback))
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    do { try engine.start() } catch { return }
    self.engine = engine
    // The engine stops itself when the output device changes; the next packet restarts it.
    configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopPlayback() }
    }
    idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, ProcessInfo.processInfo.systemUptime - self.lastPacket > 2 else { return }
        self.stopPlayback()
      }
    }
  }

  /// Runs on the audio render thread, outside the main actor.
  private nonisolated static func renderBlock(_ playback: OSAllocatedUnfairLock<AudioJitterBuffer>) -> AVAudioSourceNodeRenderBlock {
    return { _, _, frameCount, bufferList in
      let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
      guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
        let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      playback.withLock { $0.pull(Int(frameCount), left, right) }
      return noErr
    }
  }

  private func stopPlayback() {
    idleTimer?.invalidate(); idleTimer = nil
    if let engine {
      engine.stop()
    }
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = nil
    engine = nil
    playback.withLock { $0 = AudioJitterBuffer() }
  }

  // MARK: Core Audio helpers

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  @discardableResult private static func setPeerName(_ name: String) -> Bool {
    var bundleID = driverBundleID as CFString
    var plugin = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var translate = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    let found = withUnsafeMutablePointer(to: &bundleID) {
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate,
        UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
    }
    guard found == noErr, plugin != 0 else { return false }
    var value = name as CFString
    var property = address(peerNameSelector)
    return AudioObjectSetPropertyData(plugin, &property, 0, nil, UInt32(MemoryLayout<CFString>.size), &value) == noErr
  }

  private static func device(uid: String) -> AudioObjectID {
    var cfUID = uid as CFString
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var translate = address(kAudioHardwarePropertyTranslateUIDToDevice)
    let status = withUnsafeMutablePointer(to: &cfUID) {
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate,
        UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
    }
    return status == noErr ? device : 0
  }

  private static func defaultOutputUID() -> String? {
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var output = address(kAudioHardwarePropertyDefaultOutputDevice)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &output, 0, nil, &size, &device) == noErr else { return nil }
    var uid: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var uidAddress = address(kAudioDevicePropertyDeviceUID)
    guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &size, &uid) == noErr, let uid else { return nil }
    return uid.takeRetainedValue() as String
  }
}
