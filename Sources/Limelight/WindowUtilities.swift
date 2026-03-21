import AppKit

struct FocusRect {
    let screen: NSScreen
    let rectInScreen: CGRect
}

private let ncDebugEnabled = ProcessInfo.processInfo.environment["FO_DEBUG_NC"] == "1"
private var ncDebugLastLogAt: TimeInterval = 0

private func ncDebugLog(_ message: String) {
    guard ncDebugEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - ncDebugLastLogAt >= 0.20 else { return }
    ncDebugLastLogAt = now
    print("[NC-DEBUG] \(message)")
}

/// Extracts the CGRect bounds from a CGWindowList info dict, or nil if missing/malformed.
func windowBounds(from info: [String: Any]) -> CGRect? {
    guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: dict)
}

/// Returns true when the lowercased owner name belongs to Control Center.
func isControlCenterOwner(_ lowerName: String) -> Bool {
    lowerName.contains("control center")
}

/// Returns true when the lowercased owner/app name belongs to Notification Center.
func isNotificationCenterOwner(_ lowerName: String) -> Bool {
    lowerName.contains("notification center") || lowerName.contains("notificationcenter")
}

/// Fetches all on-screen windows. Omitting `excludeDesktopElements` ensures menu-bar popups appear.
func windowListForPolling() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    return list
}

/// Returns the frontmost app's topmost window, but only if it's actually in front.
/// The window list is front-to-back ordered. If another app's substantial layer-0
/// window appears first, the frontmost app's window is behind it — return nil
/// so no cutout is drawn (e.g. clicking Finder's desktop with windows behind).
///
/// Small child windows (e.g. browser tab previews) that are fully contained within
/// a larger sibling are skipped so the main window keeps the cutout.
func frontmostAppWindowRect(from windowList: [[String: Any]]) -> FocusRect? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontApp.processIdentifier

    // Collect all layer-0 windows for the frontmost app (in z-order),
    // while respecting the "another app is in front" bail-out.
    var appWindows: [CGRect] = []
    for info in windowList {
        guard
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0,
            let bounds = windowBounds(from: info),
            bounds.width > 40,
            bounds.height > 40
        else { continue }

        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { continue }

        if ownerPID == pid {
            appWindows.append(bounds)
        } else if appWindows.isEmpty {
            // Another app's window is in front — don't cut a hole for a behind-window.
            return nil
        }
    }

    // Pick the topmost window that isn't fully contained within a larger sibling.
    for bounds in appWindows {
        let area = bounds.width * bounds.height
        let isContained = appWindows.contains { sibling in
            let siblingArea = sibling.width * sibling.height
            return sibling != bounds
                && siblingArea > area
                && sibling.contains(bounds)
                && area / siblingArea < 0.25  // Only skip tiny children (previews, tooltips)
        }
        if !isContained {
            guard let screen = NSScreen.screens.first(where: { screenFrameInCG($0).intersects(bounds) }) else { continue }
            return FocusRect(screen: screen, rectInScreen: bounds)
        }
    }
    return nil
}

/// Returns the screen on which the frontmost app has a fullscreen window, or nil
/// if no fullscreen window is detected. Only layer 0 is checked to avoid
/// matching special windows like Finder's desktop background.
func frontAppFullscreenScreen(from windowList: [[String: Any]]) -> NSScreen? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontApp.processIdentifier
    for info in windowList {
        guard
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
            ownerPID == pid,
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0,
            let alpha = info[kCGWindowAlpha as String] as? Double,
            alpha > 0.01,
            let bounds = windowBounds(from: info)
        else { continue }
        // Only match the screen that actually contains this window's center,
        // not any screen whose dimensions happen to be similar.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for screen in NSScreen.screens {
            let cgFrame = screenFrameInCG(screen)
            guard cgFrame.contains(center) else { continue }
            if bounds.width / cgFrame.width > 0.92 && bounds.height / cgFrame.height > 0.92 {
                return screen
            }
        }
    }
    return nil
}

/// Returns true when `point` (in NS screen coordinates) lands inside a substantial,
/// layer-0 window that belongs to a regular app process (not system UI surfaces).
func isPointInRegularAppWindow(_ point: CGPoint, in windowList: [[String: Any]]) -> Bool {
    // Convert NS point to CG coordinates so we can compare directly against
    // CGWindow bounds (which use top-left origin, Y=0 at top of primary display).
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

    for info in windowList {
        guard
            let layer = info[kCGWindowLayer as String] as? Int,
            layer == 0,
            let alpha = info[kCGWindowAlpha as String] as? Double,
            alpha > 0.01,
            let bounds = windowBounds(from: info),
            bounds.width > 40,
            bounds.height > 40,
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t
        else { continue }

        if ownerPID == ProcessInfo.processInfo.processIdentifier { continue }

        guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }
        guard app.activationPolicy == .regular else { continue }

        if bounds.contains(cgPoint) {
            return true
        }
    }
    return false
}

/// Fast pre-filter: returns true if any Notification Center window exists.
/// Uses the already-fetched CGWindowList — no AX overhead.
///
/// Prefer the known NC layer (23) when present. Some builds may surface
/// additional NC-owned windows, so we keep a shape-based fallback.
func hasNCWindow(in windowList: [[String: Any]]) -> Bool {
    for info in windowList {
        let ownerName = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
        guard isNotificationCenterOwner(ownerName) else { continue }

        let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
        if layer == 23 {
            ncDebugLog("MATCH owner=\(ownerName) layer=23 (canonical NC layer)")
            return true
        }

        guard let bounds = windowBounds(from: info), bounds.width > 80, bounds.height > 120 else {
            ncDebugLog("owner=\(ownerName) layer=\(layer) rejected: small/missing bounds")
            continue
        }
        guard let screen = NSScreen.screens.first(where: { screenFrameInCG($0).intersects(bounds) }) else { continue }

        let frame = screen.frame
        let widthRatio = bounds.width / frame.width
        let heightRatio = bounds.height / frame.height
        let rightEdgeAligned = bounds.maxX >= frame.maxX - 24
        let tallPanelShape =
            widthRatio >= 0.10 && widthRatio <= 0.50 &&
            heightRatio >= 0.22 && heightRatio <= 1.02

        if rightEdgeAligned && tallPanelShape {
            ncDebugLog(
                "MATCH owner=\(ownerName) layer=\(layer) bounds=\(NSStringFromRect(bounds)) " +
                "wRatio=\(String(format: "%.3f", widthRatio)) hRatio=\(String(format: "%.3f", heightRatio))"
            )
            return true
        }
        ncDebugLog(
            "owner=\(ownerName) layer=\(layer) rejected: rightAligned=\(rightEdgeAligned) " +
            "wRatio=\(String(format: "%.3f", widthRatio)) hRatio=\(String(format: "%.3f", heightRatio)) " +
            "bounds=\(NSStringFromRect(bounds))"
        )
    }
    return false
}

/// Notification Center sidebar state, determined via the Accessibility API.
///
/// The NC process always shows a single fullscreen AX window at layer 23 for both
/// notification banners and the sidebar. The AX tree structure differs:
///
///   Banner:  Window → AXHostingView → AXGroup(children=2) → AXScrollArea(children=1)
///   Sidebar: Window → AXHostingView → AXGroup(children≥3) → AXScrollArea(children≥3)
///
/// During the dismiss animation the sidebar content (children≥3) lingers for ~0.5s,
/// but the mainGroup width diverges from the scroll area width as the panel slides
/// off-screen. When fully open or reopened, the two widths match.
enum NCSidebarState {
    /// No AX window, or AX query failed.
    case notPresent
    /// NC window exists but only a notification banner is showing (children < 3).
    case banner
    /// Sidebar content is present but the panel is animating (opening or dismissing).
    /// mainGroup.width diverges from scrollArea.width.
    case animating
    /// Sidebar is fully open and stable — mainGroup.width ≈ scrollArea.width.
    case fullyOpen
}

/// Queries the NC process AX tree to determine sidebar state.
/// Involves ~6 IPC calls (~5-10ms). Only call when `hasNCWindow()` is true.
func ncSidebarState() -> NCSidebarState {
    guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
        isNotificationCenterOwner(($0.localizedName ?? "").lowercased())
    }) else { return .notPresent }

    let axApp = AXUIElementCreateApplication(ncApp.processIdentifier)

    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement],
          let window = windows.first else { return .notPresent }

    // Navigate: Window → child[0] (AXHostingView) → child[0] (mainGroup)
    func firstChild(of el: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success,
              let arr = ref as? [AXUIElement], let first = arr.first else { return nil }
        return first
    }
    func axWidth(of el: AXUIElement) -> CGFloat {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &ref)
        var s = CGSize.zero
        if let v = ref { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return s.width
    }

    guard let hostingView = firstChild(of: window),
          let mainGroup = firstChild(of: hostingView) else { return .notPresent }

    // Children count distinguishes banner (2) from sidebar (≥3).
    var childrenRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(mainGroup, kAXChildrenAttribute as CFString, &childrenRef) == .success,
          let children = childrenRef as? [AXUIElement] else { return .notPresent }
    guard children.count >= 3 else { return .banner }

    // Compare mainGroup width to scroll area (first child) width.
    // Fully open: both are equal (~752pt). During animation: mainGroup widens as it slides.
    let mainWidth = axWidth(of: mainGroup)
    let scrollWidth = axWidth(of: children[0])
    if mainWidth - scrollWidth > 10 { return .animating }

    return .fullyOpen
}

func isLikelyMenuPopupWindow(info: [String: Any], bounds: CGRect, on screen: NSScreen) -> Bool {
    let frame = screen.frame
    let widthRatio = bounds.width / frame.width
    let heightRatio = bounds.height / frame.height

    let ownerName = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
    let windowName = ((info[kCGWindowName as String] as? String) ?? "").lowercased()
    let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
    let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0

    if alpha <= 0.01 { return false }

    // System menu bar strip (Window Server); we already punch a hole for the bar.
    if windowName.contains("menubar") { return false }

    // Tray/status-bar icon cells (height ≈ menu bar). On notch displays the menu
    // bar is ~37pt instead of ~24pt, so use the per-screen menu bar height.
    let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
    if bounds.height <= max(menuBarHeight + 5, 30) { return false }

    // Reject only near-fullscreen tiles.
    if widthRatio > 0.92 && heightRatio > 0.92 { return false }

    let isKnownMenuOwner =
        ownerName.contains("systemuiserver") ||
        isControlCenterOwner(ownerName) ||
        isNotificationCenterOwner(ownerName) ||
        ownerName.contains("window server") ||
        ownerName.contains("lightlight") ||
        ownerName.contains("spotlight") ||
        ownerName.contains("textinputmenuagent")
    let isLikelyMenuWindowName =
        windowName.contains("menu") ||
        windowName.contains("status") ||
        windowName.contains("control center")

    let minW: CGFloat = (isKnownMenuOwner || layer >= 24) ? 20 : 40
    let minH: CGFloat = 12
    if bounds.width < minW || bounds.height < minH { return false }

    let isMenuLikeLayer =
        (layer >= 24 && layer <= 40) ||
        layer == 101 ||
        layer == 25

    let fitsStandardPopup =
        bounds.height <= frame.height * 0.75 && bounds.width <= frame.width * 0.75
    let narrowTallSystemUI =
        widthRatio <= 0.40 &&
        heightRatio >= 0.42 && heightRatio <= 0.72 &&
        (isKnownMenuOwner || isLikelyMenuWindowName || isMenuLikeLayer)
    let controlCenterModulePanel =
        isControlCenterOwner(ownerName) &&
        layer == 101 &&
        widthRatio >= 0.12 && widthRatio <= 0.35 &&
        heightRatio >= 0.55 && heightRatio <= 0.99

    let hasMenuLikeShape = fitsStandardPopup || narrowTallSystemUI || controlCenterModulePanel
    return hasMenuLikeShape && (isKnownMenuOwner || isLikelyMenuWindowName || isMenuLikeLayer)
}
