import AppKit

/// Logical screen coordinates. The source origin is (0, 0); Y increases downward.
/// Invalid arrangements are representable for editing, but never produce mappings.
public struct ScreenArrangement: Equatable {
    public var sourceSize: CGSize
    public var remoteSize: CGSize
    public var remoteOnRight: Bool
    public var offsetY: Double

    public init(sourceSize: CGSize, remoteSize: CGSize,
                remoteOnRight: Bool, offsetY: Double) {
        self.sourceSize = sourceSize
        self.remoteSize = remoteSize
        self.remoteOnRight = remoteOnRight
        self.offsetY = offsetY
    }

    public var hasValidDimensions: Bool {
        [Double(sourceSize.width), Double(sourceSize.height),
         Double(remoteSize.width), Double(remoteSize.height)].allSatisfy {
            $0.isFinite && (64...32768).contains($0)
        } && offsetY.isFinite && abs(offsetY) <= 32768
    }

    public var sourceOrigin: CGPoint { .zero }
    public var remoteOrigin: CGPoint {
        CGPoint(x: remoteOnRight ? sourceSize.width : -remoteSize.width, y: offsetY)
    }
    public var sourceRect: CGRect { CGRect(origin: sourceOrigin, size: sourceSize) }
    public var remoteRect: CGRect { CGRect(origin: remoteOrigin, size: remoteSize) }

    /// Global logical ordinates shared by both screens, with an exclusive upper end.
    public var seamOverlap: Range<Double>? {
        guard hasValidDimensions else { return nil }
        let low = max(0, offsetY)
        let high = min(Double(sourceSize.height), offsetY + Double(remoteSize.height))
        return low < high ? low..<high : nil
    }
    public var isValid: Bool { seamOverlap != nil }

    /// Preserves global Y, without stretching, normalizing, or pixel-safe clamping.
    public func remoteY(sourceY: Double) -> Double? {
        guard sourceY.isFinite, let overlap = seamOverlap,
              overlap.contains(sourceY) else { return nil }
        let target = sourceY - offsetY
        guard target >= 0, target < Double(remoteSize.height) else { return nil }
        return target
    }

    public func sourceY(remoteY: Double) -> Double? {
        guard remoteY.isFinite, hasValidDimensions,
              remoteY >= 0, remoteY < Double(remoteSize.height),
              let overlap = seamOverlap else { return nil }
        let target = remoteY + offsetY
        guard overlap.contains(target) else { return nil }
        return target
    }
}

/// A drag uses mouse-down preview coordinates throughout, even if drawing is re-fitted.
/// The translated remote center crosses the fixed source center with a dead band.
/// Non-finite inputs are rejected; finite offsets are bounded before being proposed.
public func screenArrangementDragProposal(
    initialOffset: Double, initialMouse: CGPoint, mouse: CGPoint,
    initialRemoteCenterX: Double, sourceCenterX: Double, scale: Double,
    remoteOnRight: Bool, hysteresis: Double = 20
) -> (remoteOnRight: Bool, offsetY: Double)? {
    let values = [initialOffset, Double(initialMouse.x), Double(initialMouse.y),
                  Double(mouse.x), Double(mouse.y), initialRemoteCenterX,
                  sourceCenterX, scale, hysteresis]
    guard values.allSatisfy({ $0.isFinite }), scale > 0, hysteresis >= 0 else { return nil }
    let center = initialRemoteCenterX + (Double(mouse.x) - Double(initialMouse.x))
    let value = initialOffset + (Double(mouse.y) - Double(initialMouse.y)) / scale
    guard center.isFinite, value.isFinite else { return nil }
    var right = remoteOnRight
    if right && center < sourceCenterX - hysteresis { right = false }
    else if !right && center > sourceCenterX + hysteresis { right = true }
    return (right, max(-32768, min(32768, value)))
}

/// Schematic preview only: never captures screens, controls input, or uses a network.
@MainActor public final class ScreenArrangementView: NSView {
    public var sourceSize: CGSize = CGSize(width: 1920, height: 1080) {
        didSet { needsDisplay = true }
    }
    public var remoteSize: CGSize? { didSet { needsDisplay = true } }
    public var remoteOnRight = true { didSet { needsDisplay = true } }
    public var offsetY: Double = 0 { didSet { needsDisplay = true } }
    var receiverDesktop: ReceiverDesktop? { didSet { if oldValue != receiverDesktop { desktopDrag=nil }; needsDisplay=true } }
    var sourceOrigin: CGPoint? { didSet { needsDisplay=true } }
    var onSourceOriginChanged: ((CGPoint) -> Void)?
    private struct DesktopDrag {
        let initialMouse: CGPoint
        let initialOrigin: CGPoint
        let transform: Transform
        let desktop: ReceiverDesktop
        let sourceSize: CGSize
    }
    private var desktopDrag: DesktopDrag?
    var isSourceDragActive:Bool {desktopDrag != nil && isInteractionEnabled}
    public var isInteractionEnabled = true {
        didSet { if !isInteractionEnabled { drag = nil; desktopDrag=nil }; needsDisplay = true }
    }
    /// When installed, the owner applies or rejects both values atomically and
    /// refreshes these properties from its accepted model. Proposals never replace
    /// the accepted preview here, so a rejected non-overlap cannot remain onscreen.
    public var onArrangementChanged: ((Bool, Double) -> Void)?
    public var onOffsetChanged: ((Double) -> Void)?
    public override var isFlipped: Bool { true }

    private struct Transform {
        let scale: CGFloat
        let origin: CGPoint
    }
    private struct Drag {
        let initialMouse: CGPoint
        let initialOffset: Double
        let initialRemoteCenterX: Double
        let sourceCenterX: Double
        let transform: Transform
        var proposedRight: Bool
    }
    private var drag: Drag?

    private func validSize(_ size: CGSize) -> Bool {
        [size.width, size.height].allSatisfy { $0.isFinite && (64...32768).contains($0) }
    }
    private var previewSource: CGSize {
        validSize(sourceSize) ? sourceSize : CGSize(width: 1920, height: 1080)
    }
    private var previewRemote: CGSize {
        if let size = remoteSize, validSize(size) { return size }
        return previewSource
    }
    private var previewOffset: CGFloat {
        offsetY.isFinite ? CGFloat(max(-32768, min(32768, offsetY))) : 0
    }
    private func transform() -> Transform? {
        let source = previewSource, remote = previewRemote
        let lowY = min(0, previewOffset)
        let highY = max(source.height, previewOffset + remote.height)
        let area = bounds.insetBy(dx: 24, dy: 36)
        guard area.width > 0, area.height > 0 else { return nil }
        let scale = min(area.width / (source.width + remote.width), area.height / (highY - lowY))
        guard scale.isFinite, scale > 0 else { return nil }
        let minX: CGFloat = remoteOnRight ? 0 : -remote.width
        let origin = CGPoint(x: area.midX - (minX + (source.width + remote.width) / 2) * scale,
                             y: area.midY - (lowY + (highY - lowY) / 2) * scale)
        return Transform(scale: scale, origin: origin)
    }
    private func frames(_ t: Transform) -> (source: CGRect, remote: CGRect) {
        let source = previewSource, remote = previewRemote
        return (CGRect(x: t.origin.x, y: t.origin.y,
                       width: source.width * t.scale, height: source.height * t.scale),
                CGRect(x: t.origin.x + (remoteOnRight ? source.width : -remote.width) * t.scale,
                       y: t.origin.y + previewOffset * t.scale,
                       width: remote.width * t.scale, height: remote.height * t.scale))
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if receiverDesktop != nil {
            NSColor.windowBackgroundColor.setFill();NSBezierPath(rect:bounds).fill()
            drawDesktop();return
        }
        guard let t = transform() else { return }
        let f = frames(t)
        drawMonitor(f.source, title: "This Mac", subtitle: dimensions(previewSource), remote: false)
        let known = remoteSize.map(validSize) ?? false
        drawMonitor(f.remote, title: known ? "Remote Mac" : "Remote display",
                    subtitle: known ? dimensions(previewRemote) : "Connect to detect size", remote: true)
        let text = known ? (isInteractionEnabled ? "Drag the remote display left, right, up or down" : "Arrangement locked")
                         : "Remote display size is not available"
        drawText(text, rect: CGRect(x: bounds.minX + 8, y: bounds.maxY - 26,
                                   width: max(0, bounds.width - 16), height: 22), secondary: true)
    }
    private func dimensions(_ size: CGSize) -> String {
        String(format: "%.0f × %.0f logical points", Double(size.width), Double(size.height))
    }
    private func drawMonitor(_ rect: CGRect, title: String, subtitle: String, remote: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (remote ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (remote ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawText(title, rect: CGRect(x: rect.minX + 4, y: rect.midY - 20,
                                    width: max(0, rect.width - 8), height: 22), secondary: false)
        drawText(subtitle, rect: CGRect(x: rect.minX + 4, y: rect.midY + 3,
                                       width: max(0, rect.width - 8), height: 20), secondary: true)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawText(_ text: String, rect: CGRect, secondary: Bool) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: secondary ? 11 : 13, weight: secondary ? .regular : .semibold),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style
        ])
    }


    private func desktopTransform() -> Transform? {
        if let active=desktopDrag { return active.transform }
        guard let desktop=receiverDesktop,desktop.valid,let origin=sourceOrigin,ReceiverDesktop.finite(origin),validSize(sourceSize) else{return nil}
        let union=desktop.bounds.union(CGRect(origin:origin,size:sourceSize))
        let area=bounds.insetBy(dx:24,dy:40)
        guard area.width>0,area.height>0,union.width>0,union.height>0 else{return nil}
        let scale=min(area.width/union.width,area.height/union.height)
        guard scale.isFinite,scale>0 else{return nil}
        return Transform(scale:scale,origin:CGPoint(x:area.midX-union.midX*scale,y:area.midY-union.midY*scale))
    }
    private func desktopFrame(_ rect:CGRect,_ t:Transform)->CGRect {
        CGRect(x:t.origin.x+rect.minX*t.scale,y:t.origin.y+rect.minY*t.scale,width:rect.width*t.scale,height:rect.height*t.scale)
    }
    // Local view geometry only, also used by native-free UI event regressions.
    func desktopSourceFrame()->CGRect? {guard let t=desktopTransform(),let origin=sourceOrigin else{return nil};return desktopFrame(CGRect(origin:origin,size:sourceSize),t)}
    func desktopReceiverFrame(id:UInt32)->CGRect? {guard let t=desktopTransform(),let d=receiverDesktop?.displays.first(where:{$0.id==id}) else{return nil};return desktopFrame(d.bounds,t)}
    private func drawDesktop() {
        guard let desktop=receiverDesktop,desktop.valid,let origin=sourceOrigin,let t=desktopTransform() else{
            drawText(TCText("Waiting for the authenticated Receiver Mac's screen layout."),rect:bounds.insetBy(dx:12,dy:60),secondary:true);return
        }
        for (index,d) in desktop.displays.enumerated() {
            let kind=d.id==desktop.virtualDisplayID ? TCText("Virtual Extended Display") : (d.id==desktop.mainID ? TCText("Main Display") : TCText("Display"))
            drawMonitor(desktopFrame(d.bounds,t),title:TCText("Receiver display {0}", "\(index+1)"),subtitle:kind+TCText(" / Read-only"),remote:false)
        }
        let source=CGRect(origin:origin,size:sourceSize)
        drawMonitor(desktopFrame(source,t),title:TCText("Sender Mac"),subtitle:isInteractionEnabled ? TCText("Drag only this display") : TCText("Waiting for layout change"),remote:true)
        NSColor.controlAccentColor.setStroke()
        for portal in desktop.portals(sourceRect:source) {
            let a:CGPoint,b:CGPoint
            switch portal.sourceSide {
            case .left: a=CGPoint(x:source.minX,y:portal.intervalStart);b=CGPoint(x:source.minX,y:portal.intervalEnd)
            case .right: a=CGPoint(x:source.maxX,y:portal.intervalStart);b=CGPoint(x:source.maxX,y:portal.intervalEnd)
            case .top: a=CGPoint(x:portal.intervalStart,y:source.minY);b=CGPoint(x:portal.intervalEnd,y:source.minY)
            case .bottom: a=CGPoint(x:portal.intervalStart,y:source.maxY);b=CGPoint(x:portal.intervalEnd,y:source.maxY)
            }
            let path=NSBezierPath();path.move(to:CGPoint(x:t.origin.x+a.x*t.scale,y:t.origin.y+a.y*t.scale));path.line(to:CGPoint(x:t.origin.x+b.x*t.scale,y:t.origin.y+b.y*t.scale));path.lineWidth=4;path.stroke()
        }
        drawText(TCText("The Receiver layout reflects its macOS settings."),rect:CGRect(x:8,y:8,width:max(0,bounds.width-16),height:22),secondary:true)
        drawText(TCText("Cross between the two Macs at the highlighted edge."),rect:CGRect(x:8,y:bounds.maxY-26,width:max(0,bounds.width-16),height:22),secondary:true)
    }

    public override func mouseDown(with event: NSEvent) {
        drag = nil; desktopDrag=nil
        if let desktop=receiverDesktop {
            guard isInteractionEnabled,desktop.valid,validSize(sourceSize),let origin=sourceOrigin,ReceiverDesktop.finite(origin),let t=desktopTransform() else{return}
            let point=convert(event.locationInWindow,from:nil)
            guard desktopFrame(CGRect(origin:origin,size:sourceSize),t).contains(point) else{return}
            desktopDrag=DesktopDrag(initialMouse:point,initialOrigin:origin,transform:t,desktop:desktop,sourceSize:sourceSize)
            return
        }
        guard isInteractionEnabled, let remoteSize, validSize(remoteSize), validSize(sourceSize),
              offsetY.isFinite, abs(offsetY) <= 32768, let t = transform() else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard frames(t).remote.contains(point) else { return }
        let f = frames(t)
        drag = Drag(initialMouse: point, initialOffset: offsetY,
                    initialRemoteCenterX: Double(f.remote.midX),
                    sourceCenterX: Double(f.source.midX), transform: t,
                    proposedRight: remoteOnRight)
    }
    public override func mouseDragged(with event: NSEvent) {
        if receiverDesktop != nil {
            guard isInteractionEnabled,let active=desktopDrag,receiverDesktop==active.desktop,sourceSize==active.sourceSize else{desktopDrag=nil;return}
            let point=convert(event.locationInWindow,from:nil)
            let proposed=CGPoint(x:active.initialOrigin.x+(point.x-active.initialMouse.x)/active.transform.scale,y:active.initialOrigin.y+(point.y-active.initialMouse.y)/active.transform.scale)
            guard let accepted=active.desktop.snappedSourceOrigin(proposed:proposed,size:active.sourceSize),accepted != sourceOrigin else{return}
            // Only the owner may accept a proposal. Never edit receiver coordinates.
            onSourceOriginChanged?(accepted)
            needsDisplay=true
            return
        }
        guard isInteractionEnabled, var active = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let proposal = screenArrangementDragProposal(
            initialOffset: active.initialOffset, initialMouse: active.initialMouse,
            mouse: point, initialRemoteCenterX: active.initialRemoteCenterX,
            sourceCenterX: active.sourceCenterX, scale: Double(active.transform.scale),
            remoteOnRight: active.proposedRight) else { return }
        active.proposedRight = proposal.remoteOnRight
        drag = active
        guard proposal.remoteOnRight != remoteOnRight || proposal.offsetY != offsetY else { return }
        if let onArrangementChanged {
            onArrangementChanged(proposal.remoteOnRight, proposal.offsetY)
        } else {
            remoteOnRight = proposal.remoteOnRight
            offsetY = proposal.offsetY
            onOffsetChanged?(proposal.offsetY)
        }
        needsDisplay = true
    }
    public override func mouseUp(with event: NSEvent) {
        drag = nil; desktopDrag=nil
        needsDisplay = true
    }
}

/// Pure, deterministic checks; returns the number of failed checks (zero means pass).
@discardableResult public func runScreenLayoutTests() -> Int {
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool) { if !condition() { failures += 1 } }
    func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
    func model(_ sh: Double, _ rh: Double, _ offset: Double, _ right: Bool = true) -> ScreenArrangement {
        ScreenArrangement(sourceSize: CGSize(width: 1920, height: sh),
                          remoteSize: CGSize(width: 1280, height: rh), remoteOnRight: right, offsetY: offset)
    }
    for right in [false, true] {
        for (sh, rh, offset) in [(1080.0, 1440.0, 200.0), (1440, 900, -200),
                                 (900, 1440, -200), (1440, 900, 200),
                                 (64.5, 65.25, 0.25), (1080, 1080, 0)] {
            let a = model(sh, rh, offset, right)
            check(a.isValid)
            check(a.remoteOrigin.x == (right ? 1920 : -1280))
            check(a.remoteOrigin.y == offset)
            check(a.sourceOrigin == .zero)
            let low = max(0, offset), high = min(sh, offset + rh)
            for y in [low, low + (high - low) / 3, high - 0.00001] {
                check(near(a.remoteY(sourceY: y), y - offset))
                if let remote = a.remoteY(sourceY: y) { check(near(a.sourceY(remoteY: remote), y)) }
                else { check(false) }
            }
            check(a.remoteY(sourceY: high) == nil)
            check(a.remoteY(sourceY: low - 0.00001) == nil)
            check(a.sourceY(remoteY: rh) == nil)
            check(a.sourceY(remoteY: -0.00001) == nil)
            check(a.remoteY(sourceY: .nan) == nil)
            check(a.sourceY(remoteY: .infinity) == nil)
        }
    }
    let positive = model(1080, 1440, 200)
    check(positive.remoteY(sourceY: 250) == 50)
    let negative = model(1080, 900, -200)
    check(negative.remoteY(sourceY: 100) == 300)
    check(negative.sourceY(remoteY: 200) == 0)
    check(negative.sourceY(remoteY: 199.999) == nil)
    let fractional = model(64.5, 64.25, 0.375)
    check(fractional.remoteY(sourceY: 64.499) == 64.124)
    check(fractional.remoteY(sourceY: 64.5) == nil)
    check(model(100, 64.25, 0.375).remoteY(sourceY: 64.625) == nil)
    for offset in [1080.0, 2000, -900, -2000, .nan, .infinity, -.infinity, 32768.01, -32768.01] {
        let a = model(1080, 900, offset)
        check(!a.isValid)
        check(a.remoteY(sourceY: 500) == nil)
        check(a.sourceY(remoteY: 500) == nil)
    }
    for dimension in [0.0, -64, 63.999, 32768.001, .nan, .infinity, -.infinity] {
        for index in 0..<4 {
            var dims = [1920.0, 1080, 1280, 900]
            dims[index] = dimension
            let a = ScreenArrangement(sourceSize: CGSize(width: dims[0], height: dims[1]),
                                      remoteSize: CGSize(width: dims[2], height: dims[3]),
                                      remoteOnRight: true, offsetY: 0)
            check(!a.hasValidDimensions)
            check(a.remoteY(sourceY: 0) == nil)
            check(a.sourceY(remoteY: 0) == nil)
        }
    }
    check(model(64, 64, 0).isValid)
    check(model(32768, 32768, 0).isValid)
    check(model(32768, 32768, 32768).hasValidDimensions)
    check(!model(32768, 32768, 32768).isValid)
    check(model(32768, 32768, -32768).hasValidDimensions)
    check(!model(32768, 32768, -32768).isValid)
    check(model(1080, 900, 1079.75).remoteY(sourceY: 1079.875) == 0.125)
    check(model(1080, 900, -899.75).remoteY(sourceY: 0.125) == 899.875)
    return failures
}
