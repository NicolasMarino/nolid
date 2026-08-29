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

    /// Prefix shared with the CLI, which compiles this same file.
    static let prefix = "dev.nolid.command."

    /// Prefix of the channel the app answers `status` on.
    static let replyPrefix = "dev.nolid.status."

    /// Channel for one specific request.
    ///
    /// The caller invents a token, sends it as the command's `object`, and
    /// listens on the name derived from it. That does two things: two `nolid`
    /// processes running at once can no longer read each other's replies, and a
    /// process that did not see the token cannot land a forged answer on the
    /// caller's observer at all.
    ///
    /// It is not a security boundary and is not sold as one. This is a broadcast
    /// bus: any process running as the same user can observe the command, read
    /// the token and race the real reply. macOS draws no line between same-user
    /// processes — one could equally attach a debugger or replace the binary —
    /// so no token scheme can close that, and pretending otherwise would be
    /// worse than saying it plainly.
    static func replyName(for token: String) -> Notification.Name {
        Notification.Name(replyPrefix + token)
    }

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
    ///
    /// The handler receives the caller's reply token, when it sent one. Only
    /// `status` needs it; every other command answers nothing.
    static func start(handler: @escaping (Command, String?) -> Void) {
        stop()

        let center = DistributedNotificationCenter.default()
        observers = Command.allCases.map { command in
            center.addObserver(
                forName: Notification.Name(prefix + command.rawValue),
                object: nil,
                queue: .main
            ) { note in
                handler(command, note.object as? String)
            }
        }
    }

    static func stop() {
        let center = DistributedNotificationCenter.default()
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Answers a `status` with the state serialized as JSON.
    ///
    /// Silently does nothing without a token: there is no shared channel left to
    /// broadcast onto, and answering nobody is the correct behaviour for a
    /// `status` that arrived without a return address.
    static func reply(status: [String: Any], to token: String?) {
        guard let token, !token.isEmpty else { return }

        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            json = text
        } else {
            json = "{}"
        }

        DistributedNotificationCenter.default().postNotificationName(
            replyName(for: token),
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
