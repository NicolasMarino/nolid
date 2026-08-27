//
//  RemoteControl.swift
//  NoLid
//
//  Control channel for the CLI (`nolid on|off|toggle|panic|status`).
//
//  `DistributedNotificationCenter` is used because it needs no permissions,
//  opens no ports and does not require the app to expose an XPC service. The
//  command travels in the notification *name* and the reply in the `object`
//  field, a `String`: that is the part of the mechanism delivered reliably
//  between non-sandboxed processes.
//

import Foundation

enum RemoteControl {

    /// Prefix shared with the CLI. If it changes here, change `CLI/main.swift`.
    static let prefix = "dev.nolid.command."

    /// Channel the app answers `status` on.
    static let replyName = Notification.Name("dev.nolid.status")

    enum Command: String, CaseIterable {
        case on, off, toggle, panic, status

        /// Parses a `nolid://` URL. Accepts both `nolid://toggle`, where the
        /// verb lands in the host, and `nolid:///toggle`, where it lands in the
        /// path — callers spell it both ways and neither is worth rejecting.
        init?(url: URL) {
            guard url.scheme?.lowercased() == "nolid" else { return nil }
            let verb = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            self.init(rawValue: verb.lowercased())
        }
    }

    private static var observers: [NSObjectProtocol] = []

    /// Starts listening. Idempotent.
    static func start(handler: @escaping (Command) -> Void) {
        stop()

        let center = DistributedNotificationCenter.default()
        observers = Command.allCases.map { command in
            center.addObserver(
                forName: Notification.Name(prefix + command.rawValue),
                object: nil,
                queue: .main
            ) { _ in
                handler(command)
            }
        }
    }

    static func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Answers a `status` with the state serialized as JSON.
    static func reply(status: [String: Any]) {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "{}"
        }

        DistributedNotificationCenter.default().postNotificationName(
            replyName,
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
