import AppKit
import ApplicationServices

func isCommandKeyDownViaCGEventSource() -> Bool {
    // kVK_Command = 55, kVK_RightCommand = 54.
    CGEventSource.keyState(.combinedSessionState, key: 55) ||
        CGEventSource.keyState(.combinedSessionState, key: 54)
}

/// Monitors keyboard and mouse events for Cmd+Tab switcher detection and menu bar interactions.
/// Communicates back to the controller via closures rather than tight coupling.
final class InputMonitor {
    var onImmediateUpdate: (() -> Void)?
    var onMenuClose: (() -> Void)?
    var shouldOptimisticallyCloseMenu: ((CGPoint, Bool) -> Bool)?
    var onGlobalLeftMouseDown: ((CGPoint, Bool) -> Void)?
    var onDismissSystemPanelIntent: (() -> Void)?
    var onToggleOverlay: (() -> Void)?
    var hotkeyEnabled = true
    var isMenuBarPopoverOpen = false

    private(set) var commandKeyIsDown = false
    private(set) var waitingForPostSwitcherActivation = false
    private(set) var lastCommandTabDetectedAt: TimeInterval = 0

    private var switcherActiveUntil: TimeInterval = 0
    private var lastMouseDownTime: TimeInterval = 0

    // Triple-Cmd tap detection state.
    private var cmdTapTimestamps: [TimeInterval] = []
    private var cmdUsedAsShortcut = false
    private let requiredTaps = 2
    private let tapWindow: TimeInterval = 0.4
    private var keyDownMonitor: Any?
    private var flagsChangedMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseMovedMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var lastMouseMoveTrigger: TimeInterval = 0

    func start() {
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event)
        }
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleGlobalFlagsChanged(event)
        }
        // Throttled mouse-move monitor: keeps cutouts in sync as the cursor slides between menu bar
        // items while a menu is open. Capped at ~30ms to avoid spamming CGWindowListCopyWindowInfo.
        mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, isMenuBarPopoverOpen else { return }
            // When a menu is open, trigger on any mouse move (not just menu bar)
            // so submenu popups are detected promptly. Throttled to ~30ms.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastMouseMoveTrigger >= 0.03 else { return }
            lastMouseMoveTrigger = now
            onImmediateUpdate?()
        }
        // Trigger an immediate update when the user clicks in the menu bar so menu open/close
        // is detected within one window-list poll rather than waiting for the idle timer.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            // Always use NSEvent.mouseLocation for consistent NS global coordinates.
            // event.locationInWindow can differ for global events with no window.
            let loc = NSEvent.mouseLocation
            let inMenuBar = isPointInMenuBar(loc)
            handleLeftMouseDown(at: loc, inMenuBar: inMenuBar)
            guard inMenuBar else { return }
            onImmediateUpdate?()
        }
        startEventTap()
    }

    /// CGEventTap fires for mouse clicks even during menu tracking loops (which swallow
    /// NSEvent global monitor events). This lets us optimistically close menu cutouts
    /// the instant the user clicks to dismiss a menu.
    private func startEventTap() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                let loc = NSEvent.mouseLocation
                let inMenuBar = monitor.isPointInMenuBar(loc)
                monitor.handleLeftMouseDown(at: loc, inMenuBar: inMenuBar)
                if inMenuBar {
                    monitor.isMenuBarPopoverOpen = true
                    monitor.onImmediateUpdate?()
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func clearWaitingForPostSwitcherActivation() {
        waitingForPostSwitcherActivation = false
    }

    func setWaitingForPostSwitcherActivation() {
        waitingForPostSwitcherActivation = true
    }

    func refreshKeyboardStateFallback() {
        let now = ProcessInfo.processInfo.systemUptime
        let commandDown = isCommandKeyDownViaCGEventSource()
        let tabDown = CGEventSource.keyState(.combinedSessionState, key: 48)
        commandKeyIsDown = commandKeyIsDown || commandDown

        if commandDown && tabDown {
            lastCommandTabDetectedAt = now
            switcherActiveUntil = max(switcherActiveUntil, now + 1.2)
        } else if !commandDown && !commandKeyIsDown {
            switcherActiveUntil = 0
        } else if !commandDown {
            commandKeyIsDown = false
            switcherActiveUntil = 0
        }
    }

    func isSwitcherLikelyVisible() -> Bool {
        guard commandKeyIsDown || isCommandKeyDownViaCGEventSource() else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now <= switcherActiveUntil { return true }
        return now - lastCommandTabDetectedAt <= 0.2
    }

    deinit {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        if let flagsChangedMonitor { NSEvent.removeMonitor(flagsChangedMonitor) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let mouseMovedMonitor { NSEvent.removeMonitor(mouseMovedMonitor) }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }

    // MARK: - Private

    private func isPointInMenuBar(_ location: CGPoint) -> Bool {
        // Be forgiving at the edges: some displays/reporting paths can land slightly
        // above the menu-bar strip or a couple of points below it.
        let verticalPadding: CGFloat = 3
        for screen in NSScreen.screens {
            let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 26)
            let hitRect = CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight - verticalPadding,
                width: screen.frame.width,
                height: menuBarHeight + (verticalPadding * 2)
            )
            if hitRect.contains(location) {
                return true
            }
        }
        return false
    }

    /// Shared click handling for NSEvent monitor and CGEventTap.
    /// Both monitors fire for the same click — deduplicate with a timestamp guard.
    private func handleLeftMouseDown(at location: CGPoint, inMenuBar: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMouseDownTime > 0.02 else { return }
        lastMouseDownTime = now
        onGlobalLeftMouseDown?(location, inMenuBar)
        if isMenuBarPopoverOpen && (shouldOptimisticallyCloseMenu?(location, inMenuBar) ?? true) {
            onMenuClose?()
        }
    }

    private func handleGlobalKeyDown(_ event: NSEvent) {
        // kVK_Escape = 53: dismiss any open menu immediately.
        if event.keyCode == 53 {
            if isMenuBarPopoverOpen { onMenuClose?() }
            onDismissSystemPanelIntent?()
        }
        // kVK_Tab = 48.
        let isTab = event.keyCode == 48
        let hasCommand = event.modifierFlags.contains(.command)
        if isTab && hasCommand {
            commandKeyIsDown = true
            switcherActiveUntil = ProcessInfo.processInfo.systemUptime + 1.2
            onDismissSystemPanelIntent?()
            onImmediateUpdate?()
        }
        // Any key pressed while Cmd is held means this isn't a bare Cmd tap.
        if commandKeyIsDown {
            cmdUsedAsShortcut = true
        }
    }

    private func handleGlobalFlagsChanged(_ event: NSEvent) {
        let wasDown = commandKeyIsDown
        let hasCommand = event.modifierFlags.contains(.command)
        commandKeyIsDown = hasCommand

        if hasCommand && !wasDown {
            // Cmd just pressed — reset shortcut flag for this press cycle.
            cmdUsedAsShortcut = false
        } else if !hasCommand && wasDown {
            // Cmd just released — count as a tap if no other key was pressed.
            if !cmdUsedAsShortcut && hotkeyEnabled {
                let now = ProcessInfo.processInfo.systemUptime
                cmdTapTimestamps.append(now)
                cmdTapTimestamps = cmdTapTimestamps.filter { now - $0 <= tapWindow }
                if cmdTapTimestamps.count >= requiredTaps {
                    cmdTapTimestamps.removeAll()
                    onToggleOverlay?()
                }
            }
            cmdUsedAsShortcut = false
            switcherActiveUntil = 0
            onImmediateUpdate?()
        }
    }
}
