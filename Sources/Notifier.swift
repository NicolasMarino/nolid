//
//  Notifier.swift
//  NoLid
//
//  User-facing notices that never block the main thread.
//
//  An `NSAlert.runModal()` fired from the watchdog or from the CLI is
//  dangerous: it stops the main run loop at exactly the moment the user is
//  fighting with their displays, and leaves the app unable to answer anything
//  until someone clicks OK.
//
//  Primary path: `UNUserNotificationCenter`. Fallback path: a floating panel
//  that dismisses itself. Neither one blocks.
//

import AppKit
import UserNotifications

enum Notifier {

    /// `nil` while the result of the authorization request is still unknown.
    private static var authorized: Bool?

    /// The same message is not repeated until someone calls `resetThrottle()`.
    /// Prevents cascades if something fails inside a reconciliation loop.
    private static var lastMessage: String?

    private static var center: UNUserNotificationCenter? {
        // `current()` raises an Objective-C exception when the process has no
        // bundle identifier. The .app always has one, but a loose binary — while
        // debugging, for instance — does not.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Asks for permission once, at startup. Non-blocking: notices raised while
    /// the answer is still pending go out through the panel.
    static func requestAuthorization() {
        guard let center else {
            authorized = false
            return
        }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { authorized = granted }
        }
    }

    /// Allows a message that already showed to appear again. Called when the
    /// state genuinely changes, so the next failure does warn.
    static func resetThrottle() {
        lastMessage = nil
    }

    /// Notice that something did not go as expected.
    static func warn(_ message: String) {
        guard lastMessage != message else { return }
        lastMessage = message
        deliver(message)
    }

    /// Informational notice about a state change. It skips the throttle because
    /// an explicit user action triggers it.
    static func inform(_ message: String) {
        deliver(message)
    }

    // MARK: - Delivery

    private static func deliver(_ message: String) {
        guard authorized == true, let center else {
            FloatingNotice.show(message)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "NoLid"
        content.body = message

        // `trigger: nil` means deliver now. The identifier is unique so two
        // notices in a row do not overwrite each other.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            guard error != nil else { return }
            DispatchQueue.main.async { FloatingNotice.show(message) }
        }
    }
}

// MARK: - Fallback panel

/// Floating notice in the top-right corner. Dismisses itself after 6s or on
/// click. It never activates the app or steals keyboard focus.
private final class FloatingNotice: NSPanel {

    private static var current: FloatingNotice?
    private var dismissTimer: Timer?

    static func show(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { show(message) }
            return
        }
        current?.dismiss()

        let panel = FloatingNotice(message: message)
        current = panel
        panel.orderFrontRegardless()

        // In `.common` so it still dismisses itself with a menu open.
        let timer = Timer(timeInterval: 6, repeats: false) { _ in panel.dismiss() }
        RunLoop.main.add(timer, forMode: .common)
        panel.dismissTimer = timer
    }

    private init(message: String) {
        let width: CGFloat = 340
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 10),
            // `.nonactivatingPanel` is what keeps the notice from stealing focus.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "NoLid")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: message)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - 32

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        contentView = container
        // Real height from the text, now that the constraints exist.
        let fitting = container.fittingSize
        setContentSize(NSSize(width: width, height: max(fitting.height, 56)))
        reposition()
    }

    /// Top-right corner of the main screen, below the menu bar.
    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - 16,
            y: visible.maxY - frame.height - 16
        ))
    }

    override func mouseDown(with event: NSEvent) {
        dismiss()
    }

    private func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if FloatingNotice.current === self { FloatingNotice.current = nil }
        orderOut(nil)
    }
}

// MARK: - Injection seam

/// Notices are a side effect too. Under test we want to assert that a failure
/// was reported without a panel appearing on someone's screen.
protocol NoticeSink {
    func warn(_ message: String)
    func inform(_ message: String)
    func resetThrottle()
}

struct SystemNoticeSink: NoticeSink {
    func warn(_ message: String) { Notifier.warn(message) }
    func inform(_ message: String) { Notifier.inform(message) }
    func resetThrottle() { Notifier.resetThrottle() }
}
