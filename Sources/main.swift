//
//  main.swift
//  NoLid — turn off the MacBook built-in display with the lid open.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the controller, so any notice raised during startup already
        // knows whether it goes out as a notification or as a panel.
        Notifier.requestAuthorization()
        controller = MenuBarController()
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
