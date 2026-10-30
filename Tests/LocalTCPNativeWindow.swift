import AppKit
import CoreGraphics
import ApplicationServices
import IOKit

private struct LocalTCPNativeRecord {
    let type: NSEvent.EventType
    let location: CGPoint
    let windowLocation: CGPoint
    let screenLocation: CGPoint
    let delta: CGVector
    let flags: NSEvent.ModifierFlags
    let buttons: Int
    let key: UInt16
    let keyHeld: Bool
    let sourcePID: Int64?
}

private final class LocalTCPNativeView: NSView {
    var records: [LocalTCPNativeRecord] = []
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let text = "ThunderControl 로컬 입력 검사\n잠시 키보드와 마우스를 사용하지 마세요.\n수신한 OS 이벤트: \(records.count)\n검사 후 원래 화면으로 복원합니다."
        (text as NSString).draw(in: NSRect(x:24,y:bounds.height-180,width:bounds.width-48,height:156),
            withAttributes:[.font:NSFont.systemFont(ofSize:19),.foregroundColor:NSColor.labelColor])
    }
    private func record(_ event: NSEvent) {
        records.append(LocalTCPNativeRecord(type: event.type,
            location: event.cgEvent?.location ?? .zero,
            windowLocation: event.locationInWindow,
            screenLocation: event.window?.convertPoint(toScreen:event.locationInWindow) ?? .zero,
            delta: [.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.scrollWheel].contains(event.type) ? CGVector(dx:event.deltaX,dy:event.deltaY) : .zero,
            flags: event.modifierFlags,
            buttons: NSEvent.pressedMouseButtons, key: [.keyDown, .keyUp, .flagsChanged].contains(event.type) ? event.keyCode : 0,
            keyHeld: [.keyDown, .keyUp, .flagsChanged].contains(event.type) ? CGEventSource.keyState(.hidSystemState, key: event.keyCode) : false,
            sourcePID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)))
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) { record(event) }
    override func mouseDown(with event: NSEvent) { record(event) }
    override func mouseUp(with event: NSEvent) { record(event) }
    override func mouseDragged(with event: NSEvent) { record(event) }
    override func rightMouseDown(with event: NSEvent) { record(event) }
    override func rightMouseUp(with event: NSEvent) { record(event) }
    override func rightMouseDragged(with event: NSEvent) { record(event) }
    override func otherMouseDown(with event: NSEvent) { record(event) }
    override func otherMouseUp(with event: NSEvent) { record(event) }
    override func otherMouseDragged(with event: NSEvent) { record(event) }
    override func keyDown(with event: NSEvent) { record(event) }
    override func keyUp(with event: NSEvent) { record(event) }
    override func flagsChanged(with event: NSEvent) { record(event) }
    override func scrollWheel(with event: NSEvent) { record(event) }
}

private final class LocalTCPNativeKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class LocalTCPNativeWindow {
    private let target = CGRect(x: 0, y: 200, width: 600, height: 600)
    private let originalApp: NSRunningApplication
    private let originalPoint: CGPoint
    private let displays: [CGDirectDisplayID: CGRect]
    private let originalPolicy: NSApplication.ActivationPolicy
    private let view = LocalTCPNativeView(frame: .zero)
    private var window: LocalTCPNativeKeyWindow?
    private var keys: Set<CGKeyCode> = []
    private var buttons: Set<UInt32> = []
    private var connections: Set<io_connect_t> = []
    private var closed = false
    private var failures: [String] = []
    private var outsideScopePosts = 0
    private var nativeAttempts = 0
    private var nativeFailures = 0
    private var nativeTypes: Set<UInt32> = []
    private var nativePlans: [HIDInputPlan] = []
    private var observedKeys: Set<CGKeyCode> = []
    private let baselineCaps: CGEventFlags
    private var printedDiagnostics = false
    private var watchdog: Timer?
    private let system = HIDInputAPI.system
    private static func displayRects() throws -> [CGDirectDisplayID: CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success, count > 0, count < 32
        else { throw Failure("Native window blocked: active display inventory unavailable") }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
    init() throws {
        guard Thread.isMainThread else { throw Failure("Native window requires main thread") }
        guard AXIsProcessTrusted(), system.permissionCheck() else { throw Failure("Native window blocked: OS input permission unavailable") }
        let held = CGEventSource.flagsState(.hidSystemState).intersection(
            [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskHelp])
        guard held.isEmpty, !physicalInputsHeld() else {
            throw Failure("Native window blocked: physical keys, modifiers or buttons held")
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let cursor = CGEvent(source: nil)?.location
        else { throw Failure("Native window blocked: original application or cursor unavailable") }
        baselineCaps = system.readFlags().intersection(.maskAlphaShift)
        originalApp = app; originalPoint = cursor
        displays = try Self.displayRects()
        originalPolicy = NSApplication.shared.activationPolicy()
        let main = CGDisplayBounds(CGMainDisplayID())
        guard main.origin == .zero, main.contains(target), displays.values.contains(where: { $0.contains(cursor) }),
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
            }), screen.frame.origin == .zero, screen.frame.size == main.size
        else { throw Failure("Native window blocked: physical main display cannot contain owned target") }
        let appKit = NSApplication.shared
        appKit.setActivationPolicy(.regular)
        let owned = LocalTCPNativeKeyWindow(contentRect: CGRect(x: target.minX,
            y: screen.frame.height - target.maxY, width: target.width, height: target.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window = owned
        owned.title = "ThunderControl Local Input Check"
        watchdog = Timer.scheduledTimer(withTimeInterval:20,repeats:false) { [weak self] _ in
            self?.reject("Native window exceeded 20-second limit"); self?.close()
        }
        owned.isReleasedWhenClosed = false
        owned.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        owned.acceptsMouseMovedEvents = true
        owned.backgroundColor = .darkGray
        owned.contentView = view
        owned.makeFirstResponder(view)
        owned.makeKeyAndOrderFront(nil)
        appKit.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(2)
        while !ownsFocus && Date() < deadline { pumpEvents() }
        guard ownsFocus else { close(); throw Failure("Native window blocked: owned key window did not activate") }
        view.records.removeAll()
    }
    private var ownsFocus: Bool {
        !closed && Thread.isMainThread && window?.isKeyWindow == true &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
    private func allowed(_ point: CGPoint) -> Bool { ownsFocus && target.contains(point) }
    private func reject(_ message: String) { failures.append(message) }
    var inputAPI: RelayInputAPI {
        RelayInputAPI(native: HIDInputAPI(permissionCheck: {
            self.ownsFocus && self.system.permissionCheck()
        }, open: {
            guard self.ownsFocus else { self.reject("HID open outside owned focus"); return (Int32(kIOReturnNotPermitted), 0) }
            let result = self.system.open()
            if result.1 != 0 { self.connections.insert(result.1) }
            if result.0 != 0 || result.1 == 0 { self.reject("Native HID open failed") }
            return result
        }, post: { port, plan in
            let keyboard = [10, 11, 12].contains(plan.type)
            let scopedPlan = keyboard
                ? plan.motion == nil && plan.options == 1
                : [1, 2, 3, 4, 5, 6, 7, 25, 26, 27].contains(plan.type) && plan.motion != nil && self.allowed(plan.location)
            // Global-flags keyboard posts have no cursor-position option or meaningful pointer coordinate.
            guard self.ownsFocus, self.connections.contains(port), scopedPlan else {
                self.reject("HID post rejected outside owned scope"); return Int32(kIOReturnNotPermitted)
            }
            self.nativeAttempts += 1
            let result = self.system.post(port, plan)
            if result == 0 { self.nativeTypes.insert(plan.type); self.nativePlans.append(plan); self.track(plan) }
            else { self.nativeFailures += 1; self.reject("Native HID post failed") }
            return result
        }, close: { port in
            if self.connections.contains(port) {
                if !self.keys.isEmpty || !self.buttons.isEmpty || self.system.readFlags().intersection(.maskAlphaShift) != self.baselineCaps {
                    self.reject("Relay closed HID with owned inputs held"); self.safetyCleanup(port)
                }
                self.connections.remove(port); self.system.close(port)
            }
        }, readFlags: { self.system.readFlags() }), postCG: { event, tap in self.post(event, tap: tap) }, warp: { point in
            guard self.allowed(point) else { self.reject("Warp rejected outside owned scope"); return .failure }
            let result = CGWarpMouseCursorPosition(point)
            if result != .success { self.reject("Native cursor warp failed") }
            return result
        })
    }
    private func post(_ event: CGEvent, tap: CGEventTapLocation) {
        guard allowed(event.location), event.type == .scrollWheel else {
            outsideScopePosts += 1; reject("Unexpected CG ordinary input or outside owned scope"); return
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: tap)
    }
    private func track(_ plan: HIDInputPlan) {
        if [10, 11, 12].contains(plan.type) { observedKeys.insert(plan.keyCode) }
        if plan.type == 10 { keys.insert(plan.keyCode) }
        if plan.type == 11 { keys.remove(plan.keyCode) }
        if plan.type == 12, plan.keyCode != 57,
            let down = modifierDown(plan.keyCode, flags: CGEventFlags(rawValue: UInt64(plan.flags))) {
            if down { keys.insert(plan.keyCode) } else { keys.remove(plan.keyCode) }
        }
        if [1, 3, 25].contains(plan.type) { buttons.insert(UInt32(plan.button)) }
        if [2, 4, 26].contains(plan.type) { buttons.remove(UInt32(plan.button)) }
    }
    private func safetyCleanup(_ port: io_connect_t) {
        // This is an owned-scope emergency path, never a substitute for Relay cleanup.
        guard ownsFocus, connections.contains(port), let point = nativePlans.last(where: { $0.motion != nil })?.location, allowed(point) else {
            reject("Owned HID emergency cleanup unavailable"); return
        }
        for key in Array(keys) {
            let type: UInt32 = modifierDescriptors[key] == nil ? 11 : 12
            let plan = HIDInputPlan(type: type, location: point, flags: UInt32(baselineCaps.rawValue), options: 1,
                motion: nil, keyCode: key, autorepeat: false, button: 0, click: 0)
            if system.post(port, plan) == 0 { track(plan) } else { reject("Owned HID key cleanup failed") }
        }
        for button in Array(buttons) {
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                mouseButton: CGMouseButton(rawValue: button) ?? .left),
                case .plan(let plan) = HIDInputPlan.make(event: event, keyboardFlags: baselineCaps, budget: 32768)
            else { reject("Owned HID button cleanup creation failed"); continue }
            if system.post(port, plan) == 0 { track(plan) } else { reject("Owned HID button cleanup failed") }
        }
        let caps = HIDInputPlan(type: 12, location: point, flags: UInt32(baselineCaps.rawValue), options: 1,
            motion: nil, keyCode: 57, autorepeat: false, button: 0, click: 0)
        if system.post(port, caps) != 0 { reject("Owned HID Caps restoration failed") }
    }

    func pumpEvents() {
        guard Thread.isMainThread else { reject("Event pump requires main thread"); return }
        let deadline = Date().addingTimeInterval(0.005)
        while Date() < deadline, let event = NSApplication.shared.nextEvent(matching: .any,
            until: deadline, inMode: .default, dequeue: true) { NSApplication.shared.sendEvent(event) }
    }
    func count(type: UInt32) -> Int { view.records.filter { UInt32($0.type.rawValue) == type }.count }
    func waitFor(type: UInt32, count expected: Int) throws {
        let deadline = Date().addingTimeInterval(0.4)
        while count(type:type) < expected && Date() < deadline && !closed { pumpEvents() }
        guard count(type:type) >= expected else { throw Failure("Native OS event not received in time: type \(type)") }
    }
    func saveProof(to path: String) throws {
        guard ownsFocus, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure("Native proof unavailable") }
        view.displayIfNeeded(); view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw Failure("Native proof encoding failed") }
        try bytes.write(to:URL(fileURLWithPath:path))
    }
    func verify() throws {
        pumpEvents()
        var missing: [String] = []
        let records = view.records
        for (type, name) in [(NSEvent.EventType.mouseMoved, "HID mouseMoved 5"),
            (.leftMouseDragged, "HID leftDragged 6"), (.rightMouseDragged, "HID rightDragged 7"),
            (.leftMouseDown, "leftDown"), (.leftMouseUp, "leftUp"),
            (.rightMouseDown, "rightDown"), (.rightMouseUp, "rightUp"),
            (.otherMouseDown, "otherDown"), (.otherMouseUp, "otherUp"), (.otherMouseDragged, "HID otherDragged 27")] {
            if !records.contains(where: { $0.type == type }) { missing.append(name) }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if !records.contains(where: { $0.type == type && $0.key == 0 && $0.keyHeld == (type == .keyDown) }) { missing.append("HID A \(type)") }
        }
        for down in [true, false] {
            if !records.contains(where: { $0.type == .flagsChanged && $0.key == 56 && $0.flags.contains(.shift) == down }) {
                missing.append("Shift 56 \(down ? "down" : "up")")
            }
        }
        if !records.contains(where: { $0.type == .leftMouseDragged && $0.flags.contains(.shift) }) { missing.append("Shift left drag flags") }
        if !records.contains(where: { $0.type == .leftMouseDragged && ($0.buttons & 1) != 0 }) { missing.append("Left drag with left button held") }
        if !records.contains(where: { $0.type == .rightMouseDragged && ($0.buttons & 2) != 0 }) { missing.append("Right drag with right button held") }
        if !nativeTypes.isSuperset(of: [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 25, 26, 27]) { missing.append("native HID ordinary types") }
        if !records.contains(where: { $0.type == .otherMouseDragged && ($0.buttons & 4) != 0 }) { missing.append("Other drag with other button held") }
        let hidRecords = records.filter { record in
            nativePlans.contains { $0.type == UInt32(record.type.rawValue) && $0.location == record.location }
        }
        for type in [UInt32(5), 6, 7, 27] {
            if !hidRecords.contains(where: { UInt32($0.type.rawValue) == type }) { missing.append("NSEvent matching HID plan \(type)") }
        }
        for plan in nativePlans where [5, 6, 7, 27].contains(plan.type) {
            if !hidRecords.contains(where: { UInt32($0.type.rawValue) == plan.type && $0.location == plan.location && $0.delta.dx == CGFloat(plan.dx) && $0.delta.dy == CGFloat(plan.dy) }) { missing.append("NSEvent delta matching HID plan \(plan.type)") }
        }
        let pid = Int64(ProcessInfo.processInfo.processIdentifier)
        if hidRecords.isEmpty || records.filter({ [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 25, 26, 27].contains($0.type.rawValue) }).contains(where: { $0.sourcePID != pid }) { missing.append("HID source PID mismatch") }
        if !keys.isEmpty || !buttons.isEmpty { missing.append("owned held input ledger not empty") }
        if observedKeys.filter({ $0 != 57 }).contains(where: { CGEventSource.keyState(.hidSystemState, key: $0) }) || NSEvent.pressedMouseButtons != 0 { missing.append("global owned key/button state not released") }
        if system.readFlags().intersection([.maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskHelp]) != baselineCaps { missing.append("global modifier/Caps baseline not restored") }
        if outsideScopePosts != 0 || nativeFailures != 0 { missing.append("unsafe or failed native posts") }
        if !missing.isEmpty || !failures.isEmpty {
            if !printedDiagnostics {
                printedDiagnostics = true
                for record in records { print("Native event type=\(record.type.rawValue) cg=\(record.location) window=\(record.windowLocation) screen=\(record.screenLocation) delta=\(record.delta) flags=\(record.flags.rawValue) buttons=\(record.buttons) key=\(record.key)") }
                for plan in nativePlans { print("Native plan type=\(plan.type) point=\(plan.location) flags=\(plan.flags)") }
            }
            throw Failure("Native owned-window evidence missing: " + (missing + failures).joined(separator: ", "))
        }
        print("Native owned-window NSEvents verified; HID attempts=\(nativeAttempts), records=\(records.count), outsideScopePosts=\(outsideScopePosts)")
    }
    func close() {
        guard !closed else { return }
        watchdog?.invalidate(); watchdog = nil
        guard Thread.isMainThread else { reject("Close requires main thread"); return }
        for port in connections {
            if !keys.isEmpty || !buttons.isEmpty || system.readFlags().intersection(.maskAlphaShift) != baselineCaps {
                reject("Relay stop incomplete before native window close"); safetyCleanup(port)
            }
            system.close(port)
        }
        connections.removeAll()
        for _ in 0..<4 { pumpEvents() }
        closed = true
        window?.close(); window = nil
        if originalApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { _ = originalApp.activate(options: []) }
        let deadline = Date().addingTimeInterval(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != originalApp.processIdentifier && Date() < deadline { pumpEvents() }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != originalApp.processIdentifier {
            reject("Original foreground application restore failed")
        } else if (try? Self.displayRects()) != displays {
            reject("Display layout changed; cursor restoration blocked")
        } else if physicalInputsHeld() || !CGEventSource.flagsState(.hidSystemState).intersection(
            [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskHelp]).isEmpty {
            reject("Physical input held; cursor restoration blocked")
        } else if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: originalPoint, mouseButton: .left) {
            event.flags = []
            event.setIntegerValueField(.mouseEventDeltaX, value: 0); event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            event.setIntegerValueField(.eventSourceUserData, value: marker); event.post(tap: .cghidEventTap)
            let restoreDeadline = Date().addingTimeInterval(0.25)
            while CGEvent(source: nil)?.location != originalPoint && Date() < restoreDeadline { pumpEvents() }
            if CGEvent(source: nil)?.location != originalPoint { reject("Original cursor point restore failed") }
        } else { reject("Cursor restoration event creation failed") }
        NSApplication.shared.setActivationPolicy(originalPolicy)
    }
}
