import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlayController: OverlayController
    private let initialConfig: AppConfig
    private var statusItem: NSStatusItem?
    private var toggleSwitch: NSSwitch?
    private var blurSlider: NSSlider?
    private var dimSlider: NSSlider?
    private var accessibilityHintItem: NSMenuItem?
    private var accessibilityCheckTimer: Timer?
    private var overlayStarted = false
    private var didShowAccessibilityPreflightPrompt = false

    init(config: AppConfig) {
        self.initialConfig = config
        self.overlayController = OverlayController(config: config)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let trusted = AXIsProcessTrusted()

        if !trusted {
            print("Accessibility permission is required. Enable it in System Settings > Privacy & Security > Accessibility.")
        }

        setupStatusItem()
        overlayController.onPauseStateChanged = { [weak self] paused in
            DispatchQueue.main.async {
                self?.toggleSwitch?.state = paused ? .off : .on
            }
        }
        if trusted {
            startOverlayIfNeeded()
        } else {
            setControlsEnabled(false)
            accessibilityHintItem?.isHidden = false
            beginAccessibilityPolling()
            presentAccessibilityPreflightPromptIfNeeded()
        }
    }

    // MARK: - Menu Actions

    @objc private func toggleSwitchChanged(_ sender: NSSwitch) {
        overlayController.togglePause()
        sender.state = overlayController.isPaused ? .off : .on
    }

@objc private func blurSliderChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue)
        overlayController.setBlurAlpha(value)
        AppConfig.saveToDefaults(blurAlpha: value, dimAlpha: CGFloat(dimSlider?.doubleValue ?? sender.doubleValue))
    }

    @objc private func dimSliderChanged(_ sender: NSSlider) {
        let value = CGFloat(sender.doubleValue)
        overlayController.setDimAlpha(value)
        AppConfig.saveToDefaults(blurAlpha: CGFloat(blurSlider?.doubleValue ?? sender.doubleValue), dimAlpha: value)
    }

    @objc private func hotkeyToggleChanged(_ sender: NSMenuItem) {
        let enabled = sender.state == .off
        sender.state = enabled ? .on : .off
        overlayController.setHotkeyEnabled(enabled)
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = makeApertureIcon(size: 18)
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        // Toggle row
        let toggleItem = NSMenuItem()
        let toggleView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))

        let label = NSTextField(labelWithString: "Limelight")
        label.font = .menuFont(ofSize: 13)

        let toggle = NSSwitch()
        toggle.state = .on
        toggle.target = self
        toggle.action = #selector(toggleSwitchChanged(_:))
        toggle.controlSize = .mini
        toggleSwitch = toggle

        label.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggleView.addSubview(label)
        toggleView.addSubview(toggle)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: toggleView.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: toggleView.centerYAnchor),
            toggle.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: toggleView.trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: toggleView.centerYAnchor),
            toggleView.heightAnchor.constraint(equalToConstant: 28),
            toggleView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        toggleItem.view = toggleView
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())

        let accessibilityHint = NSMenuItem(
            title: "Grant Accessibility in System Settings to start (no restart required)",
            action: nil,
            keyEquivalent: ""
        )
        accessibilityHint.isEnabled = false
        accessibilityHint.isHidden = true
        accessibilityHintItem = accessibilityHint
        menu.addItem(accessibilityHint)
        menu.addItem(NSMenuItem.separator())

        // Blur slider
        let (blurItem, blur) = makeSliderItem(
            label: "Blur",
            value: Double(initialConfig.blurAlpha),
            action: #selector(blurSliderChanged(_:))
        )
        blurSlider = blur
        menu.addItem(blurItem)

        // Dim slider
        let (dimItem, dim) = makeSliderItem(
            label: "Dim",
            value: Double(initialConfig.dimAlpha),
            action: #selector(dimSliderChanged(_:))
        )
        dimSlider = dim
        menu.addItem(dimItem)

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: "Double-⌘ Toggle Shortcut",
            action: #selector(hotkeyToggleChanged(_:)),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        hotkeyItem.state = AppConfig.isHotkeyEnabled ? .on : .off
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Limelight",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func startOverlayIfNeeded() {
        guard !overlayStarted else { return }
        overlayStarted = true
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        accessibilityHintItem?.isHidden = true
        setControlsEnabled(true)
        overlayController.start()
    }

    private func beginAccessibilityPolling() {
        accessibilityCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.startOverlayIfNeeded()
            }
        }
        accessibilityCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func presentAccessibilityPreflightPromptIfNeeded() {
        guard !didShowAccessibilityPreflightPrompt else { return }
        didShowAccessibilityPreflightPrompt = true
        DispatchQueue.main.async { [weak self] in
            self?.presentAccessibilityPreflightPrompt()
        }
    }

    private func presentAccessibilityPreflightPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = "Limelight needs Accessibility access to detect active windows and apply the spotlight effect correctly.\n\nChoose Continue to open the macOS permission prompt."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            requestAccessibilityPermissionPrompt()
        }
    }

    private func requestAccessibilityPermissionPrompt() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true as CFBoolean
        ] as CFDictionary)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        toggleSwitch?.isEnabled = enabled
        blurSlider?.isEnabled = enabled
        dimSlider?.isEnabled = enabled
    }

    private func makeSliderItem(label text: String, value: Double, action: Selector) -> (NSMenuItem, NSSlider) {
        let menuItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))

        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: self, action: action)
        slider.isContinuous = true

        label.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(slider)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 30),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 32),
        ])

        menuItem.view = container
        return (menuItem, slider)
    }

    /// Draws a six-blade camera aperture icon, used as a template image in the menu bar.
    private func makeApertureIcon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = size * 0.45
            let innerRadius = radius * 0.38
            let bladeCount = 6
            let lineWidth: CGFloat = 1.2

            // Outer circle
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.05, dy: size * 0.05))
            circle.lineWidth = lineWidth
            NSColor.black.setStroke()
            circle.stroke()

            // Aperture blades — each blade is a line from an outer point to an inner
            // point rotated one step ahead, creating the characteristic overlapping pattern.
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round

            for i in 0..<bladeCount {
                let outerAngle = (CGFloat(i) / CGFloat(bladeCount)) * .pi * 2 - .pi / 2
                let innerAngle = (CGFloat(i + 1) / CGFloat(bladeCount)) * .pi * 2 - .pi / 2

                let outerPoint = CGPoint(
                    x: center.x + radius * cos(outerAngle),
                    y: center.y + radius * sin(outerAngle)
                )
                let innerPoint = CGPoint(
                    x: center.x + innerRadius * cos(innerAngle),
                    y: center.y + innerRadius * sin(innerAngle)
                )

                path.move(to: outerPoint)
                path.line(to: innerPoint)
            }

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
