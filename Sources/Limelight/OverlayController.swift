import AppKit

/// Central orchestrator: owns overlay windows, drives the polling loop, and delegates
/// subsystem concerns to InputMonitor and ControlCenterTracker.
final class OverlayController: NSObject {
    private enum SuppressionReason: String {
        case none
        case userPaused
        case switcher
        case systemPanel
        case manualResumeGate
        case noFocus
    }

    private enum PanelTransition {
        case none
        case opened
        case closed
    }

    private struct PanelSnapshot {
        let sidebarState: NCSidebarState
        let ncOpen: Bool
        let systemPanelOpen: Bool
    }

    private struct PanelSuppressionDecision {
        let reason: SuppressionReason?
        let transition: PanelTransition
    }

    private struct ScreenOverlay {
        let window: NSWindow
        let view: OverlayView
    }

    private struct FocusSignature: Equatable {
        let screenID: ObjectIdentifier
        let rectInScreen: CGRect
    }

    private struct MenuPopoverRect {
        let rectInScreen: CGRect
        let screenFrame: CGRect
    }

    private enum Timing {
        static let activePollingInterval: TimeInterval = 0.05
        static let settlingPollingInterval: TimeInterval = 0.15
        static let idlePollingInterval: TimeInterval = 1.0
        static let pollingIntervalChangeEpsilon: TimeInterval = 0.01
        static let settlingTickThreshold = 4
        static let idleTickThreshold = 10
        static let switcherReleaseGraceWindow: TimeInterval = 0.2
        static let noFocusSuppressionDelay: TimeInterval = 0.1
        static let menuOptimisticCloseTimeout: TimeInterval = 0.3
        static let ncBannerFallbackWindow: TimeInterval = 0.30
        static let ncClickProbeDelay: TimeInterval = 0.05
    }

    private var config: AppConfig
    private let inputMonitor: InputMonitor
    private let ccTracker: ControlCenterTracker

    private var overlays: [ObjectIdentifier: ScreenOverlay] = [:]
    private var timer: Timer?
    private var pollingInterval: TimeInterval = Timing.activePollingInterval
    private var stableTickCount = 0
    private var lastFocusSignature: FocusSignature?
    private var lastHoleRectsByScreen: [ObjectIdentifier: [CGRect]] = [:]
    /// Hole rects without menu popups — used for optimistic close updates.
    private var baseHoleRectsByScreen: [ObjectIdentifier: [CGRect]] = [:]
    /// Last detected menu popup rects in screen coordinates.
    private var lastMenuPopoverRectsInScreen: [MenuPopoverRect] = []
    private var overlaysSuppressed = false
    private var suppressionReason: SuppressionReason = .none
    private var systemPanelWasOpen = false
    /// Suppresses menu popup detection after an optimistic close so the poll loop
    /// doesn't re-add the cutout while the menu window is still animating out.
    private var menuOptimisticallyClosed = false
    private var menuOptimisticCloseTime: TimeInterval = 0
    private var nilFocusStartTime: TimeInterval = 0
    private var isPausedByUser = false
    private var desktopClickActive = false
    private let ncDebugEnabled = ProcessInfo.processInfo.environment["FO_DEBUG_NC"] == "1"
    private var ncDebugLastPanelState: String?
    private var recentNCHotspotClickAt: TimeInterval = 0
    /// Set when the user clicks into a regular app window while NC is still open.
    /// Once NC closes, we skip the manual-resume gate and restore immediately.
    private var pendingResumeAfterSystemPanelClose = false
    var onPauseStateChanged: ((Bool) -> Void)?

    var isPaused: Bool { isPausedByUser }

    init(config: AppConfig) {
        self.config = config
        self.inputMonitor = InputMonitor()
        self.ccTracker = ControlCenterTracker()
        super.init()
    }

    func start() {
        inputMonitor.onImmediateUpdate = { [weak self] in self?.updateHoleImmediate() }
        inputMonitor.onMenuClose = { [weak self] in self?.updateHoleAfterMenuClose() }
        inputMonitor.shouldOptimisticallyCloseMenu = { [weak self] location, inMenuBar in
            self?.shouldOptimisticallyCloseMenu(at: location, inMenuBar: inMenuBar) ?? true
        }
        inputMonitor.onGlobalLeftMouseDown = { [weak self] location, inMenuBar in
            self?.handleGlobalLeftMouseDown(at: location, inMenuBar: inMenuBar)
        }
        inputMonitor.onDismissSystemPanelIntent = { [weak self] in
            self?.handleDismissSystemPanelIntent()
        }
        inputMonitor.hotkeyEnabled = AppConfig.isHotkeyEnabled
        inputMonitor.onToggleOverlay = { [weak self] in
            guard let self else { return }
            self.togglePause()
            self.onPauseStateChanged?(self.isPausedByUser)
        }
        inputMonitor.start()

        rebuildOverlays()
        beginPolling()

        let workspaceNC = NSWorkspace.shared.notificationCenter
        workspaceNC.addObserver(self, selector: #selector(activeAppDidChange),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspaceNC.addObserver(self, selector: #selector(updateHoleImmediate),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func pause() {
        isPausedByUser = true
        applySuppressionReason(.userPaused)
    }

    func resume() {
        guard isPausedByUser else { return }
        isPausedByUser = false
        updateHole()
    }

    func togglePause() {
        if isPausedByUser { resume() } else { pause() }
    }

    func setBlurAlpha(_ value: CGFloat) {
        config = AppConfig(blurAlpha: value, dimAlpha: config.dimAlpha)
        overlays.values.forEach { $0.view.setBlurAlpha(value) }
    }

    func setDimAlpha(_ value: CGFloat) {
        config = AppConfig(blurAlpha: config.blurAlpha, dimAlpha: value)
        overlays.values.forEach { $0.view.setDimAlpha(value) }
    }

    func setHotkeyEnabled(_ enabled: Bool) {
        inputMonitor.hotkeyEnabled = enabled
        AppConfig.isHotkeyEnabled = enabled
    }

    // MARK: - Notifications

    @objc private func activeAppDidChange() {
        inputMonitor.clearWaitingForPostSwitcherActivation()
        if waitingForManualResumeAfterSystemPanel && !isPausedByUser {
            clearManualResumeGate(triggerImmediateUpdate: false)
        }
        updateHoleImmediate()
    }

    @objc private func screenConfigDidChange() {
        // Suppress overlays until the user focuses an app, similar to clicking
        // the desktop. This avoids a fully blurred screen with no cutout while
        // the system settles after a monitor configuration change.
        if suppressionReason == .none {
            applySuppressionReason(.noFocus)
        }
        rebuildOverlays()
        resetToActivePolling()
        updateHole()
    }

    // MARK: - Polling

    @objc private func updateHoleImmediate() {
        stableTickCount = 0
        updatePollingIntervalIfNeeded(Timing.activePollingInterval)
        updateHole()
    }

    /// Optimistic menu-close update: immediately applies the pre-computed base rects (no menu
    /// popups) so the cutout vanishes in the same frame.
    private func updateHoleAfterMenuClose() {
        inputMonitor.isMenuBarPopoverOpen = false
        lastMenuPopoverRectsInScreen.removeAll()
        menuOptimisticallyClosed = true
        menuOptimisticCloseTime = ProcessInfo.processInfo.systemUptime
        for (screenID, overlay) in overlays {
            if let base = baseHoleRectsByScreen[screenID] {
                overlay.view.setHoleRects(base)
                lastHoleRectsByScreen[screenID] = base
            }
        }
        // Commit the mask change to the render server now, before the menu's
        // dismiss reaches the compositor — eliminates the 1-frame gap where
        // the cutout is visible but the menu is already gone.
        CATransaction.flush()
        stableTickCount = 0
        updatePollingIntervalIfNeeded(Timing.activePollingInterval)
    }

    private func shouldOptimisticallyCloseMenu(at location: CGPoint, inMenuBar: Bool) -> Bool {
        // Menu-bar clicks should still close/reopen quickly as the user switches items.
        if inMenuBar { return true }
        guard inputMonitor.isMenuBarPopoverOpen else { return false }

        // If this click lands inside a currently-open popup, don't force-close.
        if isPointInMenuPopover(location, rects: lastMenuPopoverRectsInScreen) {
            return false
        }

        // Re-sample once to avoid stale-rect races when the popup moved since last poll.
        let windowList = windowListForPolling()
        let hasCCLayer101 = ccTracker.containsLayer101(in: windowList)
        for screen in NSScreen.screens where screen.frame.insetBy(dx: -2, dy: -2).contains(location) {
            let menuRects = menuPopoverRects(from: windowList, hasCCLayer101: hasCCLayer101, on: screen)
            let entries = menuRects.map { rect in
                MenuPopoverRect(rectInScreen: rect, screenFrame: screen.frame)
            }
            if isPointInMenuPopover(location, rects: entries) {
                return false
            }
        }
        return true
    }

    private func isPointInMenuPopover(_ location: CGPoint, rects: [MenuPopoverRect]) -> Bool {
        rects.contains { entry in
            let expanded = entry.rectInScreen.insetBy(dx: -3, dy: -3)
            if expanded.contains(location) { return true }

            // Some CGWindow bounds are reported in top-left Y origin.
            let yFromTop = expanded.minY - entry.screenFrame.minY
            let flippedY = entry.screenFrame.maxY - yFromTop - expanded.height
            let flipped = CGRect(
                x: expanded.minX,
                y: flippedY,
                width: expanded.width,
                height: expanded.height
            )
            return flipped.contains(location)
        }
    }

    private func handleGlobalLeftMouseDown(at location: CGPoint, inMenuBar: Bool) {
        if inMenuBar && isLikelyNotificationCenterHotspotClick(location) {
            recentNCHotspotClickAt = ProcessInfo.processInfo.systemUptime
        }
        if handleSystemPanelClickIntent(at: location, inMenuBar: inMenuBar) { return }
        if handleManualResumeGateClickIntent(at: location, inMenuBar: inMenuBar) { return }

        if !isPausedByUser, !inMenuBar {
            let windowList = windowListForPolling()
            if isPointInRegularAppWindow(location, in: windowList) {
                // Clicking an app window clears the desktop-click gate.
                if desktopClickActive {
                    desktopClickActive = false
                    applySuppressionReason(.none)
                    updateHoleImmediate()
                }
            } else {
                // Don't treat dock-area clicks as desktop clicks — the user
                // is launching/switching an app, not dismissing focus.
                let inDock = NSScreen.screens.contains { screen in
                    dockRectInScreen(on: screen)?.contains(location) == true
                }
                if !inDock {
                    desktopClickActive = true
                    applySuppressionReason(.noFocus)
                }
            }
        }
    }

    private func handleSystemPanelClickIntent(at location: CGPoint, inMenuBar: Bool) -> Bool {
        // If NC is currently suppressing overlays, remember an explicit click into a regular
        // app window as intent to resume immediately once NC actually closes.
        guard suppressionReason == .systemPanel, !inMenuBar, !isPausedByUser else { return false }
        recentNCHotspotClickAt = 0
        let windowList = windowListForPolling()
        if isPointInRegularAppWindow(location, in: windowList) {
            pendingResumeAfterSystemPanelClose = true
            resetToActivePolling()
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.ncClickProbeDelay) { [weak self] in
            guard let self, self.suppressionReason == .systemPanel, !self.isPausedByUser else { return }
            let delayedList = windowListForPolling()
            if !hasNCWindow(in: delayedList), frontmostAppWindowRect(from: delayedList) != nil {
                self.pendingResumeAfterSystemPanelClose = true
            }
        }
        return true
    }

    @discardableResult
    private func handleManualResumeGateClickIntent(at location: CGPoint, inMenuBar: Bool) -> Bool {
        guard waitingForManualResumeAfterSystemPanel, !inMenuBar, !isPausedByUser else { return false }
        // Any non-menu-bar click while gated is an explicit "I'm done with the panel"
        // intent. We still prefer a verified app-window hit, but fall back to a short
        // delayed probe to absorb NC dismiss animation timing.
        recentNCHotspotClickAt = 0
        let windowList = windowListForPolling()
        if isPointInRegularAppWindow(location, in: windowList) {
            clearManualResumeGate(triggerImmediateUpdate: true)
            return true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.ncClickProbeDelay) { [weak self] in
            guard let self, self.waitingForManualResumeAfterSystemPanel, !self.isPausedByUser else { return }
            let delayedList = windowListForPolling()
            if frontmostAppWindowRect(from: delayedList) != nil {
                self.clearManualResumeGate(triggerImmediateUpdate: true)
            }
        }
        return true
    }

    private func handleDismissSystemPanelIntent() {
        guard waitingForManualResumeAfterSystemPanel, !isPausedByUser else { return }
        clearManualResumeGate(triggerImmediateUpdate: true)
    }

    private func clearManualResumeGate(triggerImmediateUpdate: Bool) {
        applySuppressionReason(.none)
        recentNCHotspotClickAt = 0
        if triggerImmediateUpdate {
            updateHoleImmediate()
        }
    }

    private func handlePanelDecision(_ panelDecision: PanelSuppressionDecision) -> Bool {
        switch panelDecision.transition {
        case .opened:
            systemPanelWasOpen = true
            resetToActivePolling()
        case .closed:
            systemPanelWasOpen = false
            pendingResumeAfterSystemPanelClose = false
            resetToActivePolling()
        case .none:
            break
        }
        guard let panelReason = panelDecision.reason else { return false }
        applySuppressionReason(panelReason)
        tickStabilityAndMaybeSlowPolling()
        return true
    }

    private func tickStabilityAndMaybeSlowPolling() {
        stableTickCount += 1
        guard stableTickCount >= Timing.settlingTickThreshold else { return }
        updatePollingIntervalIfNeeded(
            stableTickCount >= Timing.idleTickThreshold
                ? Timing.idlePollingInterval
                : Timing.settlingPollingInterval
        )
    }

    private func clearMenuOptimisticCloseIfNeeded(windowList: [[String: Any]]) {
        guard menuOptimisticallyClosed else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - menuOptimisticCloseTime
        let anyMenuWindowRemains = windowList.contains { info in
            guard let bounds = windowBounds(from: info) else { return false }
            return NSScreen.screens.contains { screen in
                screen.frame.intersects(bounds)
                    && isLikelyMenuPopupWindow(info: info, bounds: bounds, on: screen)
            }
        }
        if !anyMenuWindowRemains || elapsed > Timing.menuOptimisticCloseTimeout {
            menuOptimisticallyClosed = false
        }
    }

    /// Resolves the current focused app-window cutout target.
    /// Returns nil when no focus target is available for this tick (and handles suppression).
    private func resolveFocusRectOrSuppress(windowList: [[String: Any]]) -> FocusRect? {
        let focusRect = frontmostAppWindowRect(from: windowList)

        // No window to focus on (e.g. clicked desktop) — suppress the overlay
        // rather than showing a fully blurred screen with no cutout.
        // Require 100ms of continuous nil before suppressing to avoid a
        // full-screen flash during app switches, where the window list z-order
        // updates before NSWorkspace.frontmostApplication does.
        guard let focusRect else {
            // If a menu bar popup is open, the user is interacting with the
            // menu — don't treat nil focus as "no app focused."
            if inputMonitor.isMenuBarPopoverOpen {
                resetToActivePolling()
                return nil
            }
            let now = ProcessInfo.processInfo.systemUptime
            if nilFocusStartTime == 0 { nilFocusStartTime = now }
            if now - nilFocusStartTime >= Timing.noFocusSuppressionDelay {
                applySuppressionReason(.noFocus)
            }
            resetToActivePolling()
            return nil
        }

        nilFocusStartTime = 0
        applySuppressionReason(.none)
        return focusRect
    }

    /// Prepares Control Center tracking state.
    private func resolveWindowListContext(windowList: [[String: Any]]) -> Bool {
        let hasCCLayer101 = ccTracker.containsLayer101(in: windowList)
        if !hasCCLayer101 {
            ccTracker.resetState()
        }
        return hasCCLayer101
    }

    private func composeAndApplyHoleRects(
        focusRect: FocusRect?,
        windowList: [[String: Any]],
        hasCCLayer101: Bool
    ) -> (didChange: Bool, anyMenuOpen: Bool, menuPopoverRectsInScreen: [MenuPopoverRect]) {
        var didChange = false
        var anyMenuOpen = false
        var menuPopoverRectsInScreen: [MenuPopoverRect] = []

        for screen in NSScreen.screens {
            let screenID = ObjectIdentifier(screen)
            guard let overlay = overlays[screenID] else { continue }
            var holeRects: [CGRect] = []

            if let menuBarRect = menuBarRectInScreen(on: screen) {
                holeRects.append(toOverlayLocalRect(screenBounds: menuBarRect, on: screen))
            }

            if let dockRect = dockRectInScreen(on: screen) {
                holeRects.append(toOverlayLocalRect(screenBounds: dockRect, on: screen))
            }

            if let focusRect, screen == focusRect.screen {
                holeRects.append(toOverlayLocalRect(windowBounds: focusRect.rectInScreen, on: screen))
            }

            baseHoleRectsByScreen[screenID] = holeRects

            if !menuOptimisticallyClosed {
                let menuRects = menuPopoverRects(from: windowList, hasCCLayer101: hasCCLayer101, on: screen)
                if !menuRects.isEmpty { anyMenuOpen = true }
                menuPopoverRectsInScreen.append(contentsOf: menuRects.map { rect in
                    MenuPopoverRect(rectInScreen: rect, screenFrame: screen.frame)
                })
                for rect in menuRects {
                    holeRects.append(toOverlayLocalRect(windowBounds: rect, on: screen))
                }
            }

            if lastHoleRectsByScreen[screenID] != holeRects {
                overlay.view.setHoleRects(holeRects)
                lastHoleRectsByScreen[screenID] = holeRects
                didChange = true
            }
        }

        return (didChange, anyMenuOpen, menuPopoverRectsInScreen)
    }

    /// Handles Cmd+Tab switcher suppression and post-switcher settle behavior.
    /// Returns true when updateHole should early-return for this tick.
    private func handleSwitcherState() -> Bool {
        if inputMonitor.isSwitcherLikelyVisible() {
            applySuppressionReason(.switcher)
            inputMonitor.setWaitingForPostSwitcherActivation()
            lastFocusSignature = nil
            resetToActivePolling()
            return true
        }

        if inputMonitor.waitingForPostSwitcherActivation {
            let now = ProcessInfo.processInfo.systemUptime
            let commandStillDown = isCommandKeyDownViaCGEventSource() || inputMonitor.commandKeyIsDown
            if commandStillDown {
                resetToActivePolling()
                return true
            }
            if now - inputMonitor.lastCommandTabDetectedAt <= Timing.switcherReleaseGraceWindow {
                resetToActivePolling()
                return true
            }
            inputMonitor.clearWaitingForPostSwitcherActivation()
            resetToActivePolling()
        }

        return false
    }

    /// Heuristic hotspot for the menu-bar area that opens Notification Center.
    private func isLikelyNotificationCenterHotspotClick(_ location: CGPoint) -> Bool {
        let verticalPadding: CGFloat = 3
        for screen in NSScreen.screens {
            let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 26)
            let menuBarRect = CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight - verticalPadding,
                width: screen.frame.width,
                height: menuBarHeight + (verticalPadding * 2)
            )
            guard menuBarRect.contains(location) else { continue }
            let hotspotWidth = min(220.0, max(140.0, screen.frame.width * 0.12))
            return location.x >= (screen.frame.maxX - hotspotWidth)
        }
        return false
    }

    private func beginPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.updateHole()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updatePollingIntervalIfNeeded(_ newInterval: TimeInterval) {
        guard abs(newInterval - pollingInterval) > Timing.pollingIntervalChangeEpsilon else { return }
        pollingInterval = newInterval
        beginPolling()
    }

    private func resetToActivePolling() {
        stableTickCount = 0
        updatePollingIntervalIfNeeded(Timing.activePollingInterval)
    }

    // MARK: - Overlay Visibility

    private func suppressOverlays() {
        guard !overlaysSuppressed else { return }
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlaysSuppressed = true
    }

    private func showOverlays() {
        guard overlaysSuppressed else { return }
        overlays.values.forEach { $0.window.makeKeyAndOrderFront(nil) }
        overlaysSuppressed = false
    }

    private var waitingForManualResumeAfterSystemPanel: Bool {
        suppressionReason == .manualResumeGate
    }

    private func applySuppressionReason(_ reason: SuppressionReason) {
        guard suppressionReason != reason else { return }
        suppressionReason = reason
        if reason == .none {
            showOverlays()
        } else {
            suppressOverlays()
        }
    }

    private func computePanelSnapshot(windowList: [[String: Any]]) -> PanelSnapshot {
        let hasNC = hasNCWindow(in: windowList)
        let sidebarState: NCSidebarState = hasNC ? ncSidebarState() : .notPresent
        let sinceNCHotspotClick = ProcessInfo.processInfo.systemUptime - recentNCHotspotClickAt
        let ncBannerAfterHotspotClick = hasNC
            && sidebarState == .banner
            && sinceNCHotspotClick <= Timing.ncBannerFallbackWindow
        let ncOpen = hasNC && (
            sidebarState == .fullyOpen ||
            sidebarState == .animating ||
            ncBannerAfterHotspotClick
        )
        return PanelSnapshot(
            sidebarState: sidebarState,
            ncOpen: ncOpen,
            systemPanelOpen: ncOpen
        )
    }

    private func decidePanelSuppression(panel: PanelSnapshot) -> PanelSuppressionDecision {
        if panel.systemPanelOpen {
            return PanelSuppressionDecision(
                reason: .systemPanel,
                transition: systemPanelWasOpen ? .none : .opened
            )
        }
        if systemPanelWasOpen {
            if pendingResumeAfterSystemPanelClose {
                return PanelSuppressionDecision(reason: nil, transition: .closed)
            }
            return PanelSuppressionDecision(reason: .manualResumeGate, transition: .closed)
        }
        if waitingForManualResumeAfterSystemPanel {
            return PanelSuppressionDecision(reason: .manualResumeGate, transition: .none)
        }
        return PanelSuppressionDecision(reason: nil, transition: .none)
    }

    private func logPanelDebugStateIfNeeded(panel: PanelSnapshot) {
        guard ncDebugEnabled else { return }
        let state = "ncOpen=\(panel.ncOpen) sidebarState=\(panel.sidebarState) systemPanelOpen=\(panel.systemPanelOpen) waitingResume=\(waitingForManualResumeAfterSystemPanel) reason=\(suppressionReason.rawValue)"
        guard state != ncDebugLastPanelState else { return }
        ncDebugLastPanelState = state
        print("[NC-DEBUG] panelState \(state)")
    }

    private func rebuildOverlays() {
        overlays.values.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        lastHoleRectsByScreen.removeAll()

        let shouldSuppress = suppressionReason != .none

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let overlayView = OverlayView(frame: screen.frame, config: config)
            window.contentView = overlayView

            if shouldSuppress {
                // Keep new windows hidden — suppression is active.
            } else {
                window.makeKeyAndOrderFront(nil)
            }

            overlays[ObjectIdentifier(screen)] = ScreenOverlay(window: window, view: overlayView)
        }

        // Sync flag with actual window visibility after replacing all overlays.
        overlaysSuppressed = shouldSuppress
    }

    // MARK: - Core Update Loop

    private func updateHole() {
        inputMonitor.refreshKeyboardStateFallback()

        if isPausedByUser {
            applySuppressionReason(.userPaused)
            updatePollingIntervalIfNeeded(Timing.idlePollingInterval)
            return
        }

        // Single window-list snapshot for the entire tick to avoid redundant IPC.
        let windowList = windowListForPolling()

        if desktopClickActive {
            // Re-check: if we now have a valid focus rect, the desktop-click was a
            // false positive (stale window list at click time). Self-correct.
            if frontmostAppWindowRect(from: windowList) != nil {
                desktopClickActive = false
                applySuppressionReason(.none)
                showOverlays()
            } else {
                // Nothing to do — let the timer settle while we wait for a click.
                tickStabilityAndMaybeSlowPolling()
                return
            }
        }

        if handleSwitcherState() { return }
        let hasCCLayer101 = resolveWindowListContext(windowList: windowList)

        let fullscreenScreen = frontAppFullscreenScreen(from: windowList)

        if fullscreenScreen == nil {
            let panel = computePanelSnapshot(windowList: windowList)
            let panelDecision = decidePanelSuppression(panel: panel)
            logPanelDebugStateIfNeeded(panel: panel)

            if handlePanelDecision(panelDecision) {
                return
            }
        }

        // When the front app is fullscreen, hide the overlay on that screen
        // (it would render on top due to .canJoinAllSpaces) and show full blur
        // on other screens since nothing is focused there.
        let focusRect: FocusRect?
        if fullscreenScreen != nil {
            focusRect = nil
            applySuppressionReason(.none)
            let fsID = ObjectIdentifier(fullscreenScreen!)
            for (screenID, overlay) in overlays {
                if screenID == fsID {
                    overlay.window.orderOut(nil)
                } else {
                    overlay.window.makeKeyAndOrderFront(nil)
                }
            }
        } else {
            // Restore any previously hidden fullscreen-screen overlay.
            if !overlaysSuppressed {
                for overlay in overlays.values where !overlay.window.isVisible {
                    overlay.window.makeKeyAndOrderFront(nil)
                }
            }
            guard let resolved = resolveFocusRectOrSuppress(windowList: windowList) else { return }
            focusRect = resolved
        }

        // Clear menu optimistic close once dismiss completes or safety timeout hits.
        clearMenuOptimisticCloseIfNeeded(windowList: windowList)

        let focusSignature: FocusSignature? = focusRect.map {
            FocusSignature(screenID: ObjectIdentifier($0.screen), rectInScreen: $0.rectInScreen)
        }
        let composition = composeAndApplyHoleRects(
            focusRect: focusRect,
            windowList: windowList,
            hasCCLayer101: hasCCLayer101
        )
        let didChange = (focusSignature != lastFocusSignature) || composition.didChange

        lastFocusSignature = focusSignature
        lastMenuPopoverRectsInScreen = composition.menuPopoverRectsInScreen
        inputMonitor.isMenuBarPopoverOpen = composition.anyMenuOpen

        if didChange {
            resetToActivePolling()
        } else if composition.anyMenuOpen {
            // A menu is open but stable — don't go to idle. Keep settling speed
            // (150ms) so menu dismissal is detected promptly. Event-driven handlers
            // (mouse move, CGEventTap) can't reliably detect clicks inside menus
            // because macOS menu tracking consumes them.
            stableTickCount += 1
            updatePollingIntervalIfNeeded(Timing.settlingPollingInterval)
        } else {
            // Three-tier: active (50ms) → settling (150ms) → idle (1s).
            // Event-driven mechanisms (CGEventTap, workspace notifications,
            // global monitors) handle most transitions; idle polling only
            // needs to catch window moves/resizes.
            tickStabilityAndMaybeSlowPolling()
        }
    }

    // MARK: - Menu Popup Detection

    private func menuPopoverRects(from windowList: [[String: Any]], hasCCLayer101: Bool, on screen: NSScreen) -> [CGRect] {
        var rects: [CGRect] = []
        let cgFrame = screenFrameInCG(screen)
        for info in windowList {
            guard let bounds = windowBounds(from: info) else { continue }
            // Use the popup's center point to assign it to exactly one screen,
            // avoiding duplicate slivers on adjacent displays.
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            guard cgFrame.contains(center) else { continue }
            if isLikelyMenuPopupWindow(info: info, bounds: bounds, on: screen) {
                rects.append(clampedMenuPopupRect(info: info, bounds: bounds, on: screen, windowList: windowList))
            }
        }
        return rects
    }

    private func clampedMenuPopupRect(
        info: [String: Any],
        bounds: CGRect,
        on screen: NSScreen,
        windowList: [[String: Any]]
    ) -> CGRect {
        let ownerName = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
        let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
        let isControlCenter101 = isControlCenterOwner(ownerName) && layer == 101 && bounds.width >= 360

        if isControlCenter101 {
            return ccTracker.clampedRectForCutout(info: info, bounds: bounds, on: screen, windowList: windowList)
        }

        // Expand left, right, and bottom by 4pt to cover the popup's rounded corners.
        // Don't expand upward — the top edge sits flush against the menu bar.
        // Clamp to the screen's CG frame (bounds are in CG coordinates).
        return CGRect(
            x: bounds.minX - 4, y: bounds.minY,
            width: bounds.width + 8, height: bounds.height + 4
        ).intersection(screenFrameInCG(screen))
    }

}
