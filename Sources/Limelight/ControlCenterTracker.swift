import AppKit
import ApplicationServices

/// Encapsulates all Control Center-specific state and detection logic.
///
/// Tracks the sticky icon anchor and AX frame cache that were previously
/// scattered across OverlayController's instance variables.
final class ControlCenterTracker {
    // Sticky anchor state: remembers which tray icon owns the current CC panel.
    private var stickyLayer101WindowID: Int?
    private var stickyIconMinX: CGFloat?
    private var stickyLayer101BoundsMinX: CGFloat?

    // AX frame cache: throttled to ~2 Hz IPC.
    private var axLastFetchUptime: TimeInterval = 0
    private var axCachedRectScreen: CGRect?
    private var axCachedPID: pid_t = -1
    private var axCachedWindowID: Int = -1
    private let axMinFetchInterval: TimeInterval = 0.5

    /// Reset all CC state when the layer-101 window disappears (panel closed).
    func resetState() {
        stickyLayer101WindowID = nil
        stickyIconMinX = nil
        stickyLayer101BoundsMinX = nil
        axCachedRectScreen = nil
        axCachedPID = -1
        axLastFetchUptime = 0
    }

    /// Returns true if the window list contains a Control Center layer-101 backing surface.
    func containsLayer101(in windowList: [[String: Any]]) -> Bool {
        windowList.contains { info in
            let owner = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            guard isControlCenterOwner(owner),
                  let l = info[kCGWindowLayer as String] as? Int, l == 101,
                  let b = windowBounds(from: info), b.width >= 360 else { return false }
            return true
        }
    }

    /// Computes the clamped cutout rect for a Control Center layer-101 window.
    /// Tries AX-based tight bounds first, falls back to heuristic sizing.
    func clampedRectForCutout(
        info: [String: Any],
        bounds: CGRect,
        on screen: NSScreen,
        windowList: [[String: Any]]
    ) -> CGRect {
        let cgFrame = screenFrameInCG(screen)
        let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let layer101Wid = info[kCGWindowNumber as String] as? Int ?? -1

        let icons = narrowIconRects(
            from: windowList,
            ownerPID: ownerPID,
            layer101Bounds: bounds,
            on: screen
        )

        // Try AX-based tight bounds first.
        if let axScreen = cachedOrFetchAccessibilityFrame(
            pid: ownerPID,
            windowID: layer101Wid,
            layer101Bounds: bounds,
            screenFrame: cgFrame
        ) {
            let axCutout = axScreen.intersection(cgFrame)
            if !axCutout.isNull && !axCutout.isEmpty && axCutout.width >= 60 && axCutout.height >= 40 {
                return axCutout
            }
        }

        // Heuristic fallback: clamp the backing surface to a plausible module size.
        let maxModuleW = min(300, bounds.width * 0.56)
        let maxModuleH = min(240, cgFrame.height * 0.19)
        let w = min(bounds.width, maxModuleW)
        let h = min(bounds.height, maxModuleH)
        let (x, _) = anchorXForCutout(
            layer101Bounds: bounds,
            holeWidth: w,
            iconRects: icons,
            screen: screen,
            layer101WindowID: layer101Wid
        )
        let y = bounds.minY
        return CGRect(x: x, y: y, width: w, height: h).intersection(cgFrame)
    }

    // MARK: - Icon Detection

    /// Narrow Control Center tray cells (layer 25) used to anchor the cutout under the active icon.
    private func narrowIconRects(
        from windowList: [[String: Any]],
        ownerPID: pid_t,
        layer101Bounds: CGRect,
        on screen: NSScreen
    ) -> [CGRect] {
        let cgFrame = screenFrameInCG(screen)
        let lo = layer101Bounds.minX - 140
        let hi = layer101Bounds.maxX + 60
        var rects: [CGRect] = []
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPID else { continue }
            let owner = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            guard isControlCenterOwner(owner) else { continue }
            guard let l = info[kCGWindowLayer as String] as? Int, l == 25 else { continue }
            guard let b = windowBounds(from: info), cgFrame.intersects(b) else { continue }
            guard b.height <= 30, b.width >= 18, b.width <= 50 else { continue }
            guard b.midX >= lo, b.midX <= hi else { continue }
            rects.append(b)
        }
        return rects.sorted { $0.minX < $1.minX }
    }

    // MARK: - Cutout Anchoring

    /// Horizontal position: leading edge of the cutout aligns with the left edge of the tray icon
    /// that owns the module. Keeps a sticky anchor while the same layer-101 window is open.
    private func anchorXForCutout(
        layer101Bounds: CGRect,
        holeWidth: CGFloat,
        iconRects: [CGRect],
        screen: NSScreen,
        layer101WindowID: Int
    ) -> (x: CGFloat, placement: String) {
        let cgFrame = screenFrameInCG(screen)
        let mouse = NSEvent.mouseLocation
        let mouseOnThisScreen = NSMouseInRect(mouse, screen.frame, false)

        func clampLeading(_ rawX: CGFloat) -> CGFloat {
            let minX = max(cgFrame.minX, layer101Bounds.minX - 120)
            let maxX = min(layer101Bounds.maxX + 48, cgFrame.maxX) - holeWidth
            return min(max(rawX, minX), maxX)
        }

        func fallbackCenter(_ tag: String) -> (CGFloat, String) {
            let slack = layer101Bounds.width - holeWidth
            let x = slack > 8 ? (layer101Bounds.minX + slack / 2) : layer101Bounds.minX
            return (clampLeading(x), tag)
        }

        guard !iconRects.isEmpty else {
            return fallbackCenter("centerInBounds_fallbackNoIcons")
        }

        // Module switch within same window: backing minX steps when changing CC modules.
        if stickyLayer101WindowID == layer101WindowID, let prevB = stickyLayer101BoundsMinX,
           abs(layer101Bounds.minX - prevB) > 22 {
            stickyIconMinX = nil
        }

        if stickyLayer101WindowID == layer101WindowID,
           let stick = stickyIconMinX,
           let prevB = stickyLayer101BoundsMinX,
           abs(layer101Bounds.minX - prevB) <= 22 {
            return (clampLeading(stick), "stickyIconMinX=\(String(format: "%.1f", stick))")
        }

        let inMenuBar = mouseOnThisScreen && mouseYIsInMenuBarStrip(mouse, on: screen)

        var chosen: CGRect?
        var placementTag = ""

        if inMenuBar {
            chosen = iconRects.first { mouse.x >= $0.minX && mouse.x <= $0.maxX }
            if chosen != nil { placementTag = "menuBarHitTest" }
            if chosen == nil {
                chosen = iconRects.min(by: { a, b in
                    horizontalDistance(from: mouse.x, toInterval: a) <
                        horizontalDistance(from: mouse.x, toInterval: b)
                })
                placementTag = "menuBarNearestInterval"
            }
        }

        if chosen == nil {
            let target = layer101Bounds.minX + 93
            chosen = iconRects.min(by: { a, b in
                abs(a.minX - target) < abs(b.minX - target)
            })
            placementTag = "fallbackMinX≈layer101+93"
        }

        guard let icon = chosen else {
            return fallbackCenter("centerInBounds_fallbackNoPick")
        }

        let rawLeading = icon.minX
        stickyLayer101WindowID = layer101WindowID
        stickyIconMinX = rawLeading
        stickyLayer101BoundsMinX = layer101Bounds.minX

        return (clampLeading(rawLeading), "\(placementTag) leadingMinX=\(String(format: "%.1f", rawLeading))")
    }

    private func horizontalDistance(from x: CGFloat, toInterval rect: CGRect) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }

    // MARK: - Accessibility Frame Cache

    /// Returns a screen-space rect from AX, throttled to ~2 Hz. Cache is invalidated when
    /// the layer-101 window ID changes (user switches CC modules).
    private func cachedOrFetchAccessibilityFrame(
        pid: pid_t,
        windowID: Int,
        layer101Bounds: CGRect,
        screenFrame: CGRect
    ) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let now = ProcessInfo.processInfo.systemUptime

        if pid != axCachedPID || windowID != axCachedWindowID {
            axCachedPID = pid
            axCachedWindowID = windowID
            axCachedRectScreen = nil
            axLastFetchUptime = 0
        }

        if now - axLastFetchUptime < axMinFetchInterval {
            return axCachedRectScreen
        }

        axLastFetchUptime = now

        let app = AXUIElementCreateApplication(pid)
        if let r = axChildrenUnionRectForCCModule(app: app, layer101Bounds: layer101Bounds, screenFrame: screenFrame) {
            axCachedRectScreen = r
            return r
        }

        return axCachedRectScreen
    }
}
