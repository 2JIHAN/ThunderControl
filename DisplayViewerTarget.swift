import AppKit
import CoreGraphics

struct DisplayViewerScreenCandidate {
    let builtIn: Bool
    let active: Bool
    let frame: CGRect
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let safeLeft: CGFloat
    let safeRight: CGFloat
    var fullScreenSize: CGSize? {
        guard active, frame.width.isFinite, frame.height.isFinite,
              [safeTop, safeBottom, safeLeft, safeRight].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let result = CGSize(width: frame.width - safeLeft - safeRight, height: frame.height - safeTop - safeBottom)
        guard result.width > 0, result.height > 0 else { return nil }
        return result
    }
    static func preferredIndex(_ screens: [Self], mainIndex: Int?) -> Int? {
        if let index = screens.indices.first(where: { screens[$0].builtIn && screens[$0].fullScreenSize != nil }) { return index }
        if let index = mainIndex, screens.indices.contains(index), screens[index].fullScreenSize != nil { return index }
        return screens.indices.first(where: { screens[$0].fullScreenSize != nil })
    }
}

/// Read-only viewer-side screen selection. Full-screen content normally excludes
/// the camera housing; subtract safe area, NOT Dock/menu-bar visibleFrame. This
/// does not write a display mode, mirror relationship, origin or scaling setting.
@MainActor struct DisplayViewerTarget {
    let screen: NSScreen?
    let format: DisplayVideoFormat
    static func read() -> Self {
        let screens = NSScreen.screens
        let candidates = screens.map { screen -> DisplayViewerScreenCandidate in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number?.uint32Value ?? 0
            let insets = screen.safeAreaInsets
            return DisplayViewerScreenCandidate(builtIn: id != 0 && CGDisplayIsBuiltin(id) != 0,
                active: id != 0 && CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0,
                frame: screen.frame, safeTop: insets.top, safeBottom: insets.bottom,
                safeLeft: insets.left, safeRight: insets.right)
        }
        let mainIndex = NSScreen.main.flatMap { main in screens.firstIndex(where: { $0 === main }) }
        guard let index = DisplayViewerScreenCandidate.preferredIndex(candidates, mainIndex: mainIndex),
              let size = candidates[index].fullScreenSize else { return Self(screen: nil, format: .hiDPI(for:CGSize(width:1440,height:900))) }
        return Self(screen: screens[index], format: .hiDPI(for:size))
    }
}
