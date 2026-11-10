import AppKit
import QuartzCore

enum ReturnBoundaryFeedback {
    case pushing(portal: DesktopPortal, point: CGPoint, distance: Double)
    case released(crossed: Bool)
}

struct ReturnBoundaryGeometry {
    static let maximumDepth = 26.0
    let frame: CGRect
    let targetEdge: DesktopSide
    let anchor: CGPoint
    var depthKey: String { targetEdge == .left || targetEdge == .right ? "transform.scale.x" : "transform.scale.y" }

    // CG and NSScreen coordinates are logical points, never backing pixels.
    init(portal: DesktopPortal, point: CGPoint, screenFrame: CGRect) {
        let r = portal.targetRect
        let vertical = portal.sourceSide == .left || portal.sourceSide == .right
        let lo = max(portal.intervalStart, vertical ? r.minY : r.minX)
        let hi = min(portal.intervalEnd, vertical ? r.maxY : r.maxX)
        let length = min(140, max(1, hi - lo))
        let tangent = min(max(vertical ? point.y : point.x, lo + length / 2), hi - length / 2)
        let depth = min(CGFloat(Self.maximumDepth), vertical ? r.width : r.height)
        let cg: CGRect
        switch portal.sourceSide {
        case .left:
            targetEdge = .right; anchor = CGPoint(x: 1, y: 0.5)
            cg = CGRect(x: r.maxX - depth, y: tangent - length / 2, width: depth, height: length)
        case .right:
            targetEdge = .left; anchor = CGPoint(x: 0, y: 0.5)
            cg = CGRect(x: r.minX, y: tangent - length / 2, width: depth, height: length)
        case .top:
            targetEdge = .bottom; anchor = CGPoint(x: 0.5, y: 0)
            cg = CGRect(x: tangent - length / 2, y: r.maxY - depth, width: length, height: depth)
        case .bottom:
            targetEdge = .top; anchor = CGPoint(x: 0.5, y: 1)
            cg = CGRect(x: tangent - length / 2, y: r.minY, width: length, height: depth)
        }
        frame = CGRect(x: screenFrame.minX + (cg.minX-r.minX)/r.width*screenFrame.width,
                       y: screenFrame.minY + (r.maxY-cg.maxY)/r.height*screenFrame.height,
                       width: cg.width/r.width*screenFrame.width, height: cg.height/r.height*screenFrame.height)
    }

    func path() -> CGPath {
        let vertical = targetEdge == .left || targetEdge == .right
        let depth = vertical ? frame.width : frame.height
        let length = vertical ? frame.height : frame.width
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            switch targetEdge {
            case .left: return CGPoint(x: x, y: y)
            case .right: return CGPoint(x: frame.width-x, y: y)
            case .bottom: return CGPoint(x: y, y: x)
            case .top: return CGPoint(x: y, y: frame.height-x)
            }
        }
        let path = CGMutablePath()
        path.move(to: p(0, 1))
        path.addCurve(to: p(depth-1, length/2), control1: p(0, length*0.28), control2: p(depth-1, length*0.28))
        path.addCurve(to: p(0, length-1), control1: p(depth-1, length*0.72), control2: p(0, length*0.72))
        path.closeSubpath()
        return path
    }

    static func stretch(_ distance: Double) -> Double {
        let u = distance.isFinite ? min(10_000, max(0, distance)) : 0
        return (u * maximumDepth * 1.5 / (maximumDepth + 1.5 * u)) / (maximumDepth - 1)
    }

}

struct ReturnBoundarySpring {
    let position: Double
    let velocity: Double
    let target: Double
    let startedAt: Double
    let responseScale: Double
    static let duration = 0.65

    init(position: Double, velocity: Double, target: Double, startedAt: Double, responseScale: Double = 1) {
        self.position = position; self.velocity = velocity; self.target = target
        self.startedAt = startedAt; self.responseScale = responseScale
    }

    func sample(at time: Double) -> (position: Double, velocity: Double) {
        let t = max(0, time - startedAt)
        let alpha = 9.0 / responseScale
        let omega = sqrt(179.0) / responseScale
        let a = position - target
        let b = (velocity + alpha * a) / omega
        let wave = a * cos(omega * t) + b * sin(omega * t)
        let decay = exp(-alpha * t)
        return (target + decay * wave,
                decay * ((-a * omega * sin(omega * t) + b * omega * cos(omega * t)) - alpha * wave))
    }

    func retarget(_ target: Double, at time: Double, responseScale: Double? = nil) -> Self {
        let current = sample(at: time)
        return Self(position: current.position, velocity: current.velocity, target: target, startedAt: time,
                    responseScale: responseScale ?? self.responseScale)
    }

    func animation(key: String) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        let duration = Self.duration * responseScale
        let count = Int((duration * 120).rounded())
        animation.values = (0...count).map { sample(at: startedAt + Double($0) * duration / Double(count)).position }
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = startedAt
        return animation
    }
}

final class ReturnBoundaryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ReturnBoundaryOverlay {
    private(set) var panel: ReturnBoundaryPanel?
    private(set) var membrane: CAShapeLayer?
    private var portal: DesktopPortal?
    private var screenFrame: CGRect?
    private var geometry: ReturnBoundaryGeometry?
    private var dismissal: DispatchWorkItem?
    private var motionReduced = false
    private(set) var depthSpring: ReturnBoundarySpring?
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func receive(_ feedback: ReturnBoundaryFeedback) {
        switch feedback {
        case let .pushing(portal, point, distance): push(portal: portal, point: point, distance: distance)
        case let .released(crossed): release(crossed: crossed)
        }
    }

    // The preview supplies its dedicated demo bounds, without touching the pointer.
    func push(portal: DesktopPortal, point: CGPoint, distance: Double, previewFrame: CGRect? = nil) {
        dismissal?.cancel(); dismissal = nil
        let isNew = self.portal != portal || panel == nil
        if isNew {
            reset()
            let frame = previewFrame ?? NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == portal.displayID
            })?.frame
            guard let frame else { return }
            self.portal = portal; screenFrame = frame; motionReduced = reducedMotion()
            let panel = ReturnBoundaryPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .statusBar
            let view = NSView(); view.wantsLayer = true; panel.contentView = view
            let shape = CAShapeLayer()
            shape.fillColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            shape.strokeColor = nil
            shape.lineWidth = 0; view.layer?.addSublayer(shape)
            self.panel = panel; membrane = shape
        }
        guard let panel, let membrane, let screenFrame else { return }
        let g = ReturnBoundaryGeometry(portal: portal, point: point, screenFrame: screenFrame)
        let shapeChanged = geometry?.frame.size != g.frame.size || geometry?.targetEdge != g.targetEdge
        geometry = g
        if panel.frame != g.frame { panel.setFrame(g.frame, display: false) }
        if shapeChanged {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            membrane.bounds = CGRect(origin: .zero, size: g.frame.size)
            membrane.anchorPoint = g.anchor
            membrane.position = CGPoint(x: g.frame.width*g.anchor.x, y: g.frame.height*g.anchor.y)
            membrane.path = g.path()
            membrane.contentsScale = panel.backingScaleFactor
            if isNew {
                membrane.setValue(ReturnBoundaryGeometry.stretch(0), forKeyPath: g.depthKey)
                membrane.opacity = 0
            }
            CATransaction.commit()
        }
        animate(g.depthKey, to: ReturnBoundaryGeometry.stretch(distance), spring: !motionReduced)
        membrane.removeAnimation(forKey: "opacity")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        membrane.opacity = 1
        CATransaction.commit()
        if !panel.isVisible { panel.orderFront(nil) }
        let idle = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.release(crossed: false) } }
        dismissal = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: idle)
    }

    private func animate(_ key: String, to target: Double, spring: Bool, responseScale: Double = 1, duration: Double = 0.10, delay: Double = 0) {
        guard let membrane else { return }
        let from = membrane.presentation()?.value(forKeyPath: key) ?? membrane.value(forKeyPath: key) ?? target
        let animation: CAAnimation
        if spring {
            let now = membrane.convertTime(CACurrentMediaTime(), from: nil)
            let next = depthSpring?.retarget(target, at: now, responseScale: responseScale)
                ?? ReturnBoundarySpring(position: (from as? NSNumber)?.doubleValue ?? target, velocity: 0, target: target, startedAt: now, responseScale: responseScale)
            depthSpring = next
            animation = next.animation(key: key)
        } else {
            if key != "opacity" { depthSpring = nil }
            let basic = CABasicAnimation(keyPath: key)
            basic.fromValue = from; basic.toValue = target; basic.duration = duration
            animation = basic
        }
        if delay > 0 {
            animation.beginTime = membrane.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        membrane.setValue(target, forKeyPath: key)
        CATransaction.commit()
        membrane.add(animation, forKey: key)
    }

    private func release(crossed: Bool) {
        guard let geometry, panel != nil else { return }
        dismissal?.cancel()
        let scale = motionReduced ? 1.0 : 1.2
        animate(geometry.depthKey, to: crossed ? ReturnBoundaryGeometry.stretch(10_000) : 0, spring: !motionReduced, responseScale: scale)
        animate("opacity", to: 0, spring: false, duration: motionReduced ? 0.10 : (crossed ? 0.18 : 0.28) * scale, delay: motionReduced || crossed ? 0 : 0.16 * scale)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reset() } }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (motionReduced ? 0.12 : ReturnBoundarySpring.duration * scale), execute: work)
    }

    func reset() {
        dismissal?.cancel(); dismissal = nil
        membrane?.removeAllAnimations(); panel?.orderOut(nil); panel?.close()
        membrane = nil; panel = nil; portal = nil; screenFrame = nil; geometry = nil; depthSpring = nil
    }
}
