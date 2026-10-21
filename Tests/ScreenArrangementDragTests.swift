import AppKit

// Run without event taps, event posting, cursor changes, settings, or networking:
// swiftc -swift-version 5 -target arm64-apple-macos13 ScreenLayout.swift \
//   Tests/ScreenArrangementDragTests.swift -o /tmp/screen-arrangement-tests
enum ScreenArrangementDragTests {
    @MainActor static func run() {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            assertions += 1
            if !condition() { fatalError("FAIL: \(name)") }
        }
        func proposal(_ x: Double, _ y: Double = 50, _ right: Bool = true,
                      _ scale: Double = 0.5, _ initial: Double = 10,
                      _ band: Double = 20) -> (remoteOnRight: Bool, offsetY: Double)? {
            screenArrangementDragProposal(initialOffset: initial,
                initialMouse: CGPoint(x: 300, y: 50), mouse: CGPoint(x: x, y: y),
                initialRemoteCenterX: 320, sourceCenterX: 100,
                scale: scale, remoteOnRight: right, hysteresis: band)
        }
        let fromLeft = screenArrangementDragProposal(initialOffset: -15,
            initialMouse: CGPoint(x: 75, y: 50), mouse: CGPoint(x: 296, y: 60),
            initialRemoteCenterX: 0, sourceCenterX: 200, scale: 0.5,
            remoteOnRight: false)
        expect(fromLeft!.remoteOnRight && fromLeft!.offsetY == 5,
               "initial-left drag crosses source with off-center grab and preserves Y")
        expect(proposal(300)!.remoteOnRight, "right stays right")
        expect(!proposal(59)!.remoteOnRight, "translated grab center crosses left threshold")
        expect(proposal(60)!.remoteOnRight, "exact left threshold retains side")
        expect(!proposal(100, 50, false)!.remoteOnRight, "exact right threshold retains side")
        expect(proposal(101, 50, false)!.remoteOnRight, "left crosses right threshold")
        var side = true
        for x in [59.0, 61, 79, 81, 99, 100] {
            side = proposal(x, 50, side)!.remoteOnRight
            expect(!side, "jitter in hysteresis band stays left")
        }
        side = proposal(101, 50, side)!.remoteOnRight
        expect(side, "return beyond band switches right")
        for x in [99.0, 81, 79, 61, 60] {
            side = proposal(x, 50, side)!.remoteOnRight
            expect(side, "jitter in hysteresis band stays right")
        }
        expect(proposal(59, 75)!.offsetY == 60, "side flip preserves positive Y delta")
        expect(proposal(101, 25, false)!.offsetY == -40, "reverse flip preserves negative Y delta")
        expect(proposal(300, 50)!.offsetY == 10, "no initial jump")
        expect(proposal(300, 100000)!.offsetY == 32768, "positive clamp")
        expect(proposal(300, -100000)!.offsetY == -32768, "negative clamp")
        expect(proposal(300, 50, true, 0.5, 32768)!.offsetY == 32768, "inclusive positive bound")
        expect(proposal(300, 50, true, 0.5, -32768)!.offsetY == -32768, "inclusive negative bound")
        for bad in [Double.nan, .infinity, -.infinity] {
            expect(proposal(bad) == nil, "non-finite X rejected")
            expect(proposal(300, bad) == nil, "non-finite Y rejected")
            expect(proposal(300, 50, true, bad) == nil, "non-finite scale rejected")
            expect(proposal(300, 50, true, 0.5, bad) == nil, "non-finite offset rejected")
            expect(proposal(300, 50, true, 0.5, 0, bad) == nil, "non-finite hysteresis rejected")
        }
        for scale in [0.0, -1] { expect(proposal(300, 50, true, scale) == nil, "non-positive scale rejected") }
        expect(proposal(300, 50, true, 0.5, 0, -1) == nil, "negative hysteresis rejected")
        for bad in [Double.nan, .infinity] {
            expect(screenArrangementDragProposal(initialOffset: 0,
                initialMouse: CGPoint(x: bad, y: 0), mouse: .zero,
                initialRemoteCenterX: 100, sourceCenterX: 50, scale: 1,
                remoteOnRight: true) == nil, "invalid initial mouse rejected")
            expect(screenArrangementDragProposal(initialOffset: 0,
                initialMouse: .zero, mouse: .zero, initialRemoteCenterX: bad,
                sourceCenterX: 50, scale: 1, remoteOnRight: true) == nil, "invalid remote center rejected")
            expect(screenArrangementDragProposal(initialOffset: 0,
                initialMouse: .zero, mouse: .zero, initialRemoteCenterX: 100,
                sourceCenterX: bad, scale: 1, remoteOnRight: true) == nil, "invalid source center rejected")
        }

        // Local synthetic events are delivered directly to the view, never posted.
        let view = ScreenArrangementView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.sourceSize = CGSize(width: 1000, height: 1000)
        view.remoteSize = view.sourceSize
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        // Use conversion through the real NSView without attaching a window.
        func localEvent(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            let location = view.convert(CGPoint(x: x, y: y), to: nil)
            return event(type, location.x, location.y)
        }
        var combinedCalls = 0, legacyCalls = 0
        view.onOffsetChanged = { _ in legacyCalls += 1 }
        view.onArrangementChanged = { right, offset in
            combinedCalls += 1
            view.remoteOnRight = right
            view.offsetY = offset
        }
        expect(view.remoteOnRight, "default remote is right")
        view.mouseDown(with: localEvent(.leftMouseDown, 438, 200))
        view.mouseDragged(with: localEvent(.leftMouseDragged, 141, 227.6))
        expect(!view.remoteOnRight && abs(view.offsetY - 100) < 0.00001, "atomic side and Y event")
        view.mouseDragged(with: localEvent(.leftMouseDragged, 170, 255.2))
        expect(!view.remoteOnRight && abs(view.offsetY - 200) < 0.00001, "refit does not change threshold or Y scale")
        view.mouseDragged(with: localEvent(.leftMouseDragged, 183, 255.2))
        expect(view.remoteOnRight && abs(view.offsetY - 200) < 0.00001, "fixed source threshold returns right")
        expect(combinedCalls == 3 && legacyCalls == 0, "combined callback suppresses legacy")
        let acceptedOffset = view.offsetY
        view.onArrangementChanged = { _, _ in combinedCalls += 1 /* reject */ }
        view.mouseDragged(with: localEvent(.leftMouseDragged, 141, 100000))
        expect(view.remoteOnRight && view.offsetY == acceptedOffset, "rejected proposal leaves accepted preview intact")
        view.mouseUp(with: localEvent(.leftMouseUp, 141, 100000))
        view.offsetY = 0
        view.onArrangementChanged = nil
        view.mouseDown(with: localEvent(.leftMouseDown, 438, 200))
        view.mouseDragged(with: localEvent(.leftMouseDragged, 141, 227.6))
        expect(!view.remoteOnRight && abs(view.offsetY - 100) < 0.00001 && legacyCalls == 1, "legacy fallback updates side and offset")
        view.mouseUp(with: localEvent(.leftMouseUp, 141, 227.6))
        view.offsetY = 0
        // A side flip is re-fitted into the same bounds: the left remote is now
        // at x=24...300, not off-canvas under the initial right-side transform.
        view.mouseDown(with: localEvent(.leftMouseDown, 162, 200))
        view.mouseDragged(with: localEvent(.leftMouseDragged, 162, 227.6))
        expect(!view.remoteOnRight && abs(view.offsetY - 100) < 0.00001 && legacyCalls == 2,
               "flipped remote stays inside bounds and can be grabbed again")
        view.isInteractionEnabled = false
        view.mouseDragged(with: localEvent(.leftMouseDragged, 500, 300))
        expect(!view.remoteOnRight && legacyCalls == 2, "disabled drag cannot edit")
        expect(runScreenLayoutTests() == 0, "existing screen layout tests unchanged")
        print("PASS screen arrangement drag assertions: \(assertions)")
    }
}
