//
//  main.swift
//  NoLid — turn off the MacBook built-in display with the lid open.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would each own a menu bar icon, a reconfiguration callback
        // and a watchdog, and both would answer the CLI — so `nolid status`
        // would report whichever replied first. Worse, they would run competing
        // `CGBeginDisplayConfiguration` transactions against the same panel.
        guard isOnlyInstance() else {
            NSApp.terminate(nil)
            return
        }

        // Before the controller, so any notice raised during startup already
        // knows whether it goes out as a notification or as a panel.
        Notifier.requestAuthorization()
        controller = MenuBarController()
    }

    /// `true` when this process should be the one that stays.
    ///
    /// A plain "is anyone else running?" check is not enough. Two copies
    /// launched at the same moment can each see the other already registered,
    /// both conclude they are the duplicate, and both quit — leaving nothing
    /// running and no watchdog behind a display that may be off right now. So
    /// the tie is broken on a value both sides agree on: the older process
    /// wins, and process id settles the case where the timestamps match.
    private func isOnlyInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let mine = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != mine }
        guard !others.isEmpty else { return true }

        // No launch date means the other side is still starting up, and it is
        // about to run this same comparison. Defer to process id there rather
        // than guess, so both sides reach the same verdict.
        let myDate = mine.launchDate
        return others.allSatisfy { other in
            switch (myDate, other.launchDate) {
            case let (mine?, theirs?) where mine != theirs:
                return mine < theirs
            default:
                return mine.processIdentifier < other.processIdentifier
            }
        }
    }

    /// `nolid://toggle`, `nolid://on`, `nolid://off`, `nolid://panic`.
    ///
    /// Same routing as the CLI and the App Intents, so a URL can never reach a
    /// code path that skips the safety nets.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = RemoteControl.Command(url: url) else { continue }
            controller?.handle(command)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A duplicate instance quits without ever having started anything. It
        // must not tear down the hardware or the channel out from under the
        // instance that is actually running.
        guard controller != nil else { return }

        // Leave the hardware in a usable state, but keep the preference so it
        // can be reapplied on the next launch.
        // Note: this does NOT run on a crash or a Force Quit. For those cases
        // there are the `.forSession` state and the panic button.
        RemoteControl.stop()
        DisplayManager.shared.enableAllDisplays(resetPreference: false)
        DisplayManager.shared.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
