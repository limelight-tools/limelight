import AppKit

/// Converts CGWindow bounds (top-left origin, Y=0 at top of primary display)
/// to overlay view local coordinates (bottom-left origin relative to the screen).
///
/// CG global and AppKit global share the same X axis but have inverted Y axes
/// anchored at the primary display.  The conversion is:
///   NS_global_y = primaryScreenHeight - CG_y - objectHeight
///   local_y     = NS_global_y - screen.frame.minY
func toOverlayLocalRect(windowBounds: CGRect, on screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let nsGlobalY = primaryHeight - windowBounds.maxY          // CG → AppKit global
    let localX = windowBounds.minX - screen.frame.minX
    let localY = nsGlobalY - screen.frame.minY                 // AppKit global → screen-local
    return CGRect(x: localX, y: localY, width: windowBounds.width, height: windowBounds.height)
}

/// Converts NSScreen-space bounds (bottom-left origin, same as NSView) to overlay view local coordinates.
func toOverlayLocalRect(screenBounds: CGRect, on screen: NSScreen) -> CGRect {
    CGRect(
        x: screenBounds.minX - screen.frame.minX,
        y: screenBounds.minY - screen.frame.minY,
        width: screenBounds.width,
        height: screenBounds.height
    )
}

func dockRectInScreen(on screen: NSScreen) -> CGRect? {
    let frame = screen.frame
    let visible = screen.visibleFrame

    let leftInset = visible.minX - frame.minX
    let rightInset = frame.maxX - visible.maxX
    let bottomInset = visible.minY - frame.minY

    enum Edge { case left, right, bottom }
    let candidates: [(edge: Edge, inset: CGFloat)] = [
        (.left, leftInset),
        (.right, rightInset),
        (.bottom, bottomInset)
    ]

    guard let best = candidates.max(by: { $0.inset < $1.inset }), best.inset > 0 else {
        return nil
    }

    switch best.edge {
    case .left:
        return CGRect(x: frame.minX, y: frame.minY, width: best.inset, height: frame.height)
    case .right:
        return CGRect(x: frame.maxX - best.inset, y: frame.minY, width: best.inset, height: frame.height)
    case .bottom:
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: best.inset)
    }
}

func menuBarRectInScreen(on screen: NSScreen) -> CGRect? {
    // When "Displays have separate Spaces" is enabled (the default since
    // macOS Mavericks), every screen has its own menu bar.  Otherwise only
    // the primary screen does.
    if NSScreen.screensHaveSeparateSpaces {
        // Every screen gets a menu bar.
    } else {
        // Only the primary screen (origin == .zero) has a menu bar.
        guard screen.frame.origin == .zero else { return nil }
    }
    // Use the per-screen top inset (frame vs visibleFrame) rather than
    // NSStatusBar.system.thickness, which is a single global value that
    // doesn't account for the taller menu bar on notch displays.
    let height = screen.frame.maxY - screen.visibleFrame.maxY
    guard height > 0 else { return nil }
    return CGRect(
        x: screen.frame.minX,
        y: screen.frame.maxY - height,
        width: screen.frame.width,
        height: height
    )
}

/// Returns the screen's frame in CG global coordinates (top-left origin, Y-down).
/// Use this when you need to intersect or compare with CGWindow bounds.
func screenFrameInCG(_ screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
    let cgY = primaryHeight - screen.frame.maxY
    return CGRect(x: screen.frame.minX, y: cgY, width: screen.frame.width, height: screen.frame.height)
}

func mouseYIsInMenuBarStrip(_ mouse: CGPoint, on screen: NSScreen) -> Bool {
    let f = screen.frame
    let t = f.maxY - screen.visibleFrame.maxY
    return mouse.y >= f.maxY - t - 2 && mouse.y <= f.maxY + 2
}
