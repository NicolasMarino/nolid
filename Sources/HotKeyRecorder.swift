//
//  HotKeyRecorder.swift
//  NoLid
//
//  Minimal panel for capturing a key combination.
//
//  It uses no text field: a local event monitor is installed while the panel
//  is on screen and it keeps the first valid keystroke.
//

import AppKit

final class HotKeyRecorder: NSObject, NSWindowDelegate {

    private var panel: NSPanel?
    private var monitor: Any?
    private var onFinish: ((HotKeyConfig?) -> Void)?
    private var hintLabel: NSTextField?

    /// Shows the panel and calls `completion` with the chosen combination, or
    /// with `nil` if the user cancels.
    func record(completion: @escaping (HotKeyConfig?) -> Void) {
        // If one was already open, cancel it before opening another.
        if panel != nil { finish(with: nil) }
        onFinish = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "NoLid hotkey"
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.delegate = self
        panel.center()

        let title = NSTextField(labelWithString: "Press the key combination")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        let hint = NSTextField(labelWithString: "Requires ⌃, ⌥ or ⌘.  Esc cancels.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hintLabel = hint

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: panel.contentLayoutRect)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
        ])
        panel.contentView = content

        // The local monitor only receives events while the app is active, so it
        // has to be activated explicitly: NoLid runs as an agent and normally
        // never holds focus.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // consumed: don't let it reach anyone else
        }

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            finish(with: nil)
            return
        }

        guard let config = HotKeyConfig(event: event) else {
            hintLabel?.stringValue = "That combination won't work. Use ⌃, ⌥ or ⌘."
            hintLabel?.textColor = .systemRed
            return
        }
        finish(with: config)
    }

    /// Single exit point: tears the monitor down, closes the panel and reports
    /// exactly once. Idempotent, so closing the window by hand does not fire
    /// the callback twice.
    private func finish(with config: HotKeyConfig?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        let callback = onFinish
        onFinish = nil
        hintLabel = nil

        if let panel {
            self.panel = nil
            panel.delegate = nil
            panel.close()
        }

        // Return the app to its resting activation policy.
        NSApp.setActivationPolicy(.accessory)
        callback?(config)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }
}
