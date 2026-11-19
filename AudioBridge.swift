import AVFoundation
import CoreAudio
import CryptoKit
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
  nonisolated static let deviceUID = "local.experimental.ThunderControl.Audio"
  nonisolated static let driverBundleID = "local.experimental.ThunderControl.AudioDriver"
  private nonisolated static let peerNameSelector = AudioObjectPropertySelector(0x7463_706E) // 'tcpn'
  private nonisolated static let audioDataSelector = AudioObjectPropertySelector(0x7463_7061) // 'tcpa'

  /// True when the user last chose the ThunderControl device while connected; restored on reconnect.
  nonisolated static let selectedKey = "ThunderControl.audioOutputUsesPeer"

  private let send: (Data) -> Void
  private var poller: DispatchSourceTimer?
  private var defaultOutputListener: AudioObjectPropertyListenerBlock?
  private let playback = OSAllocatedUnfairLock(initialState: AudioJitterBuffer())
  private var engine: AVAudioEngine?
  private var idleTimer: Timer?
  private var configObserver: NSObjectProtocol?
  private var lastPacket = 0.0

  init(send: @escaping (Data) -> Void) { self.send = send }

  /// Returns false when the driver is not installed; audio then stays off for this session.
  @discardableResult func start(peerName: String) -> Bool {
    guard let plugin = Self.plugin(), Self.setPeerName(peerName, plugin: plugin) else { return false }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ThunderControl.audio.capture", qos: .userInteractive))
    timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
    timer.setEventHandler(handler: Self.captureHandler(plugin: plugin, send: send))
    timer.resume()
    poller = timer
    var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      MainActor.assumeIsolated { self?.rememberSelection() }
    }
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    defaultOutputListener = listener
    if UserDefaults.standard.bool(forKey: Self.selectedKey) { restoreSelection() }
    return true
  }

  func stop() {
    // Stop listening before the device disappears, so macOS falling back to
    // another output is not recorded as the user's choice.
    if let listener = defaultOutputListener {
      var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
      defaultOutputListener = nil
    }
    poller?.cancel(); poller = nil
    stopPlayback()
    if let plugin = Self.plugin() { Self.setPeerName("", plugin: plugin) }
  }

  /// Plays a packet from the peer. Never plays into our own device: that would loop
  /// the audio back to the peer when both Macs select each other.
  func receive(_ pcm: Data) {
    guard Self.defaultOutputUID() != Self.deviceUID else { return }
    playback.withLock { $0.push(pcm) }
    lastPacket = ProcessInfo.processInfo.systemUptime
    if engine == nil { startPlayback() }
  }

  // MARK: Selection

  private var restoringUntil = 0.0

  private func rememberSelection() {
    guard defaultOutputListener != nil, ProcessInfo.processInfo.systemUptime >= restoringUntil else { return }
    if Self.defaultOutputUID() == Self.deviceUID { UserDefaults.standard.set(true, forKey: Self.selectedKey) }
    else if Self.device(uid: Self.deviceUID) != 0 { UserDefaults.standard.set(false, forKey: Self.selectedKey) }
  }

  /// macOS settles its own default output shortly after a device appears and can switch
  /// away from a choice made in that time, so keep reselecting until the choice has held
  /// for a second (at most 3 seconds). Changes in that window are not recorded as the user's.
  private func restoreSelection() {
    let started = ProcessInfo.processInfo.systemUptime
    restoringUntil = started + 3
    var heldSince: Double?
    func tick() {
      guard defaultOutputListener != nil else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let selected = Self.defaultOutputUID() == Self.deviceUID
      heldSince = selected ? (heldSince ?? now) : nil
      if let heldSince, now - heldSince >= 1 { restoringUntil = now }
      guard now < restoringUntil else { rememberSelection(); return }
      var device = Self.device(uid: Self.deviceUID)
      if device != 0, !selected {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { tick() }
    }
    tick()
  }

  // MARK: Capture

  /// Runs every 10 ms off the main actor. Drains the driver only while some app is playing
  /// into the device, which is rechecked every 250 ms. The driver hands over samples through
  /// a property, so no input stream is opened and macOS shows no microphone indicator.
  private nonisolated static func captureHandler(plugin: AudioObjectID, send: @escaping (Data) -> Void) -> () -> Void {
    var tick = 0
    var running = false
    var pending = Data()
    let chunk = AudioWirePolicy.chunkFrames * 4
    return {
      if tick % 25 == 0 {
        let now = isRunningSomewhere()
        if now && !running { _ = drain(plugin) } // discard samples left from an earlier session
        if !now { pending.removeAll() }
        running = now
      }
      tick += 1
      guard running, let pcm = drain(plugin) else { return }
      pending.append(pcm)
      while pending.count >= chunk {
        let packet = Data(pending.prefix(chunk))
        pending.removeFirst(chunk)
        // Exact digital silence means nothing is playing; skip it rather than stream zeros.
        if packet.contains(where: { $0 != 0 }) { DispatchQueue.main.async { send(packet) } }
      }
    }
  }

  private nonisolated static func drain(_ plugin: AudioObjectID) -> Data? {
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
    var property = address(audioDataSelector)
    guard AudioObjectGetPropertyData(plugin, &property, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as? Data
  }

  private nonisolated static func isRunningSomewhere() -> Bool {
    let device = device(uid: deviceUID)
    guard device != 0 else { return false }
    var running = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var property = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &running) == noErr && running != 0
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
      playback.withLockUnchecked { $0.pull(Int(frameCount), left, right) }
      return noErr
    }
  }

  private func stopPlayback() {
    idleTimer?.invalidate(); idleTimer = nil
    engine?.stop()
    if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    configObserver = nil
    engine = nil
    playback.withLock { $0 = AudioJitterBuffer() }
  }

  // MARK: Core Audio helpers

  private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }

  private static func plugin() -> AudioObjectID? {
    var bundleID = driverBundleID as CFString
    var plugin = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var translate = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    let status = withUnsafeMutablePointer(to: &bundleID) {
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate,
        UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
    }
    return status == noErr && plugin != 0 ? plugin : nil
  }

  @discardableResult private static func setPeerName(_ name: String, plugin: AudioObjectID) -> Bool {
    var value = name as CFString
    var property = address(peerNameSelector)
    return AudioObjectSetPropertyData(plugin, &property, 0, nil, UInt32(MemoryLayout<CFString>.size), &value) == noErr
  }

  private nonisolated static func device(uid: String) -> AudioObjectID {
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

/// The app carries the driver in Contents/Resources and installs or updates it with the
/// administrator prompt. A declined prompt is not repeated until the bundled driver changes.
enum AudioDriverInstaller {
  static let installed = "/Library/Audio/Plug-Ins/HAL/ThunderControlAudio.driver"
  static func installIfNeeded() {
    let executable = "Contents/MacOS/ThunderControlAudio"
    guard let bundled = Bundle.main.url(forResource: "ThunderControlAudio", withExtension: "driver"),
      !bundled.path.contains("'"), !bundled.path.contains("\""), !bundled.path.contains("\\"),
      let wanted = try? Data(contentsOf: bundled.appendingPathComponent(executable)) else { return }
    if (try? Data(contentsOf: URL(fileURLWithPath: installed).appendingPathComponent(executable))) == wanted { return }
    let digest = SHA256.hash(data: wanted).map { String(format: "%02x", $0) }.joined()
    let key = "audioDriverInstallAttempt"
    guard UserDefaults.standard.string(forKey: key) != digest else { return }
    UserDefaults.standard.set(digest, forKey: key)
    let prompt = TCText("ThunderControl will install its audio device so you can choose the connected Mac as a sound output.")
      .replacingOccurrences(of: "\"", with: "")
    let command = "/bin/rm -rf '\(installed)' && /usr/bin/ditto '\(bundled.path)' '\(installed)' && /usr/sbin/chown -R root:wheel '\(installed)' && /usr/bin/killall coreaudiod"
    // osascript runs outside the main thread's run loop, so input relaying keeps working while the prompt is open.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges with prompt \"\(prompt)\""]
    try? process.run()
  }
}
