//
//  MenuBarController.swift
//  NoLid
//

import AppKit
import ServiceManagement

final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let manager = DisplayManager.shared
    private let hotKey = HotKey()
    private let recorder = HotKeyRecorder()
    private var hotKeyRegistered = false
    private var checkingForUpdate = false

    override init() {
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        manager.onChange = { [weak self] in self?.refreshIcon() }
        manager.start()

        installHotKey(HotKeyConfig.load())

        RemoteControl.start { [weak self] command, replyToken in
            self?.handle(command, replyTo: replyToken)
        }

        refreshIcon()
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let off = manager.isBuiltInOff
        let symbol = off ? "display.2" : "laptopcomputer"
        let label = off ? "Built-in display off" : "Built-in display active"

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = off ? "▣" : "▤"
        }
        button.toolTip = "NoLid — \(label)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the menu is the trigger, not launch. Someone who never opens
        // it has not asked NoLid anything, and a menu bar app that phones home
        // on every login to tell nobody about it is doing it for itself.
        checkForUpdates(force: false)
        menu.removeAllItems()

        let off = manager.isBuiltInOff
        let externals = manager.externalDisplays

        menu.addItem(info(off ? "Built-in: off" : "Built-in: active"))
        menu.addItem(info("External monitors: \(externals.count)"))
        menu.addItem(.separator())

        var title = off ? "Turn on built-in display" : "Turn off built-in display"
        if hotKeyRegistered { title += "  (\(hotKey.config.label))" }
        let toggle = NSMenuItem(title: title, action: #selector(toggleBuiltIn), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = off || manager.canTurnOffBuiltIn
        menu.addItem(toggle)

        if !off && !manager.canTurnOffBuiltIn {
            menu.addItem(info("Connect an external monitor first"))
        }

        if !manager.connectedExternals.isEmpty || !manager.silenced.isEmpty {
            menu.addItem(externalsItem())
        }

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Automatic mode", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = manager.autoMode ? .on : .off
        auto.toolTip = "Turns the built-in display off when externals are connected, and back on when they are unplugged."
        menu.addItem(auto)

        menu.addItem(profilesItem())

        // With a single external there is nothing to choose, but a leftover
        // preference must still be resettable to "Automatic".
        if externals.count > 1 || manager.preferredMasterUUID != nil {
            menu.addItem(mirrorMasterItem(externals: externals))
        }

        let notify = NSMenuItem(title: "Notify on change", action: #selector(toggleNotifyOnChange), keyEquivalent: "")
        notify.target = self
        notify.state = manager.notifyOnChange ? .on : .off
        notify.toolTip = "Posts a notification whenever the built-in display is turned off or back on."
        menu.addItem(notify)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = isLoginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(hotKeyItem())
        menu.addItem(.separator())

        let panic = NSMenuItem(title: "Restore all displays", action: #selector(enableAll), keyEquivalent: "")
        panic.target = self
        menu.addItem(panic)

        menu.addItem(info("Method: \(manager.backendDescription)"))
        menu.addItem(versionItem())
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NoLid", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Profiles submenu

    private func profilesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Per-monitor profiles", action: nil, keyEquivalent: "")
        item.state = manager.profiles.enabled ? .on : .off
        item.toolTip = "Remembers whether you want the built-in display off for each set of monitors."

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let toggle = NSMenuItem(
            title: manager.profiles.enabled ? "Disable profiles" : "Enable profiles",
            action: #selector(toggleProfiles), keyEquivalent: ""
        )
        toggle.target = self
        submenu.addItem(toggle)

        submenu.addItem(.separator())
        submenu.addItem(info("Now: \(manager.topologyLabel)"))

        if manager.profiles.enabled {
            let remembered = manager.profiles.desiredOff(for: manager.topologyKey)
            switch remembered {
            case .some(true):  submenu.addItem(info("Remembered: built-in off"))
            case .some(false): submenu.addItem(info("Remembered: built-in active"))
            case .none:        submenu.addItem(info("Not remembered yet"))
            }

            if remembered != nil {
                let forget = NSMenuItem(title: "Forget this profile",
                                        action: #selector(forgetProfile), keyEquivalent: "")
                forget.target = self
                submenu.addItem(forget)
            }

            if manager.profiles.count > 0 {
                submenu.addItem(.separator())
                let clear = NSMenuItem(title: "Forget all (\(manager.profiles.count))",
                                       action: #selector(forgetAllProfiles), keyEquivalent: "")
                clear.target = self
                submenu.addItem(clear)
            }
        }

        item.submenu = submenu
        return item
    }

    // MARK: Version and updates

    private enum UpdateKey {
        static let enabled = "checkForUpdates"
        static let lastSeen = "lastSeenLatestVersion"
        static let lastCheck = "lastUpdateCheck"
    }

    /// On by default. `object(forKey:)` rather than `bool(forKey:)` so that
    /// "never chosen" reads as on, while an explicit off stays off.
    private var updateChecksEnabled: Bool {
        get { UserDefaults.standard.object(forKey: UpdateKey.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: UpdateKey.enabled) }
    }

    /// The newer version, or `nil` when this build is current.
    ///
    /// Recomputed from the stored tag every time rather than stored as a flag,
    /// so the notice disappears by itself once the update is installed.
    private var updateAvailable: String? {
        guard let latest = UserDefaults.standard.string(forKey: UpdateKey.lastSeen),
              UpdateCheck.isNewer(latest, than: NoLidVersion.current) else { return nil }
        return latest
    }

    private func checkForUpdates(force: Bool) {
        guard updateChecksEnabled || force, !checkingForUpdate else { return }

        if !force {
            let last = UserDefaults.standard.object(forKey: UpdateKey.lastCheck) as? Date
            if let last, Date().timeIntervalSince(last) < 60 * 60 * 24 { return }
        }

        checkingForUpdate = true
        UpdateCheck.fetchLatestTag { [weak self] tag in
            DispatchQueue.main.async {
                self?.checkingForUpdate = false
                // The timestamp is written even on failure. Retrying every time
                // the menu opens would turn a flaky network into a stream of
                // requests nobody asked for.
                UserDefaults.standard.set(Date(), forKey: UpdateKey.lastCheck)
                guard let tag else { return }
                UserDefaults.standard.set(tag, forKey: UpdateKey.lastSeen)
            }
        }
    }

    /// Shows the version, and says so when there is a newer one.
    private func versionItem() -> NSMenuItem {
        let newer = updateAvailable
        let item = NSMenuItem(
            title: newer.map { "Update available: \($0)" } ?? "Version \(NoLidVersion.current)",
            action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let newer {
            submenu.addItem(info("Installed: \(NoLidVersion.current)"))
            submenu.addItem(info("Latest: \(newer)"))
            submenu.addItem(.separator())
        }

        let open = NSMenuItem(title: newer == nil ? "Release notes…" : "Open the release…",
                              action: #selector(openReleases), keyEquivalent: "")
        open.target = self
        // NoLid does not install its own updates, and the reason is not
        // laziness: the CLI is half of this app, and an updater that can only
        // replace the other half would leave the two unable to talk.
        open.toolTip = "NoLid does not install updates itself. The app and the "
            + "`nolid` CLI share a control channel and have to be replaced together."
        submenu.addItem(open)

        let check = NSMenuItem(title: "Check now", action: #selector(checkNow),
                               keyEquivalent: "")
        check.target = self
        submenu.addItem(check)

        submenu.addItem(.separator())

        let auto = NSMenuItem(title: "Check automatically", action: #selector(toggleUpdateChecks),
                              keyEquivalent: "")
        auto.target = self
        auto.state = updateChecksEnabled ? .on : .off
        auto.toolTip = "Asks GitHub once a day which release is newest. The "
            + "request carries nothing about you or this Mac."
        submenu.addItem(auto)

        item.submenu = submenu
        return item
    }

    // MARK: External monitors submenu

    /// One entry per external, checked while it is on screen.
    ///
    /// The case it serves: a monitor wired to the Mac on one input and to
    /// something else on another. Switching it away leaves macOS convinced the
    /// screen is still there, so it keeps sending it windows nobody can see.
    private func externalsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "External monitors", action: nil, keyEquivalent: "")
        item.toolTip = "Turn a monitor off while it is showing another input, so "
            + "macOS stops handing it windows you cannot see."

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        var shown = Set<String>()
        for display in manager.connectedExternals {
            if let uuid = DisplayAPI.uuid(display) { shown.insert(uuid) }
            let isOff = manager.isSilenced(display)

            let entry = NSMenuItem(title: DisplayAPI.name(display),
                                   action: #selector(toggleExternal(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = NSNumber(value: display)
            entry.state = isOff ? .off : .on
            // Turning it back on is always allowed. Turning it off is not, when
            // it is the last thing left on screen.
            entry.isEnabled = isOff || manager.canDisable(display)
            submenu.addItem(entry)
        }

        // A monitor that is off can drop out of every system list, so it cannot
        // be listed from the hardware. Without these entries the only way back
        // would be unplugging it.
        let missing = manager.silenced.values
            .filter { !shown.contains($0.uuid) }
            .sorted { $0.name < $1.name }
        for record in missing {
            let entry = NSMenuItem(title: record.name,
                                   action: #selector(restoreExternal(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = record.uuid
            entry.state = .off
            submenu.addItem(entry)
        }

        if submenu.items.isEmpty { submenu.addItem(info("No external monitors")) }

        item.submenu = submenu
        return item
    }

    // MARK: Mirror master submenu

    private func mirrorMasterItem(externals: [CGDirectDisplayID]) -> NSMenuItem {
        let item = NSMenuItem(title: "Mirror master", action: nil, keyEquivalent: "")
        item.toolTip = "Which monitor the built-in display mirrors when the fallback path is in use."

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let auto = NSMenuItem(title: "Automatic", action: #selector(setMirrorMaster(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil
        auto.state = manager.preferredMasterUUID == nil ? .on : .off
        submenu.addItem(auto)

        submenu.addItem(.separator())

        let active = manager.mirrorMaster
        for display in externals {
            let entry = NSMenuItem(title: DisplayAPI.name(display),
                                   action: #selector(setMirrorMaster(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = DisplayAPI.uuid(display)
            entry.state = manager.preferredMasterUUID != nil
                && manager.preferredMasterUUID == DisplayAPI.uuid(display) ? .on : .off
            if display == active && manager.preferredMasterUUID == nil {
                entry.title += "  (in use)"
            }
            submenu.addItem(entry)
        }

        item.submenu = submenu
        return item
    }

    // MARK: Hotkey submenu

    private func hotKeyItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Hotkey: \(hotKey.config.label)", action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if !hotKeyRegistered {
            submenu.addItem(info("Taken by another app"))
            submenu.addItem(.separator())
        }

        let change = NSMenuItem(title: "Change hotkey…", action: #selector(changeHotKey), keyEquivalent: "")
        change.target = self
        submenu.addItem(change)

        let reset = NSMenuItem(title: "Reset to \(HotKeyConfig.default.label)",
                               action: #selector(resetHotKey), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = hotKey.config != .default
        submenu.addItem(reset)

        item.submenu = submenu
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleBuiltIn() { manager.toggleBuiltIn() }

    @objc private func toggleAuto() { manager.autoMode.toggle() }

    @objc private func enableAll() { manager.enableAllDisplays() }

    @objc private func toggleExternal(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let id = CGDirectDisplayID(number.uint32Value)
        manager.setExternalOff(id, !manager.isSilenced(id))
    }

    @objc private func restoreExternal(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        manager.restore(uuid)
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(UpdateCheck.releasesPage)
    }

    @objc private func checkNow() { checkForUpdates(force: true) }

    @objc private func toggleUpdateChecks() { updateChecksEnabled.toggle() }

    @objc private func toggleProfiles() {
        manager.profiles.enabled.toggle()
        refreshIcon()
    }

    @objc private func toggleNotifyOnChange() {
        manager.notifyOnChange.toggle()
        refreshIcon()
    }

    @objc private func forgetProfile() { manager.forgetCurrentProfile() }

    @objc private func forgetAllProfiles() {
        manager.profiles.forgetAll()
        refreshIcon()
    }

    @objc private func setMirrorMaster(_ sender: NSMenuItem) {
        manager.preferredMasterUUID = sender.representedObject as? String
    }

    /// Cleanup lives in `applicationWillTerminate`, not here, so it runs once.
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Global hotkey

    private func installHotKey(_ config: HotKeyConfig) {
        hotKeyRegistered = hotKey.register(config) { [weak self] in
            self?.manager.toggleBuiltIn()
        }
    }

    @objc private func changeHotKey() {
        // Release the current hotkey: otherwise recording the same combination
        // would clash with itself and look "taken by another app".
        hotKey.unregister()
        let previous = hotKey.config

        recorder.record { [weak self] config in
            guard let self else { return }
            guard let config else {
                self.installHotKey(previous)
                return
            }

            self.installHotKey(config)
            if self.hotKeyRegistered {
                config.save()
                Notifier.inform("Hotkey changed to \(config.label).")
            } else {
                // Registration failed: fall back to the previous one so the user
                // is not left without a hotkey for picking a taken one.
                self.installHotKey(previous)
                Notifier.warn("\(config.label) is already taken by another app. Keeping \(previous.label).")
            }
            self.refreshIcon()
        }
    }

    @objc private func resetHotKey() {
        HotKeyConfig.reset()
        installHotKey(.default)
        refreshIcon()
    }

    // MARK: - CLI and URL scheme

    /// Single routing point for every external trigger: the CLI channel, the
    /// `nolid://` URL scheme and the App Intents all end up here.
    ///
    /// - Parameter token: the caller's return address, present only on the CLI
    ///   channel. A URL or a Shortcuts action has nowhere to send a reply.
    func handle(_ command: RemoteControl.Command, replyTo token: String? = nil) {
        switch command {
        case .on:     manager.setBuiltInOff(false)
        case .off:    manager.setBuiltInOff(true)
        case .toggle: manager.toggleBuiltIn()
        case .panic:  manager.enableAllDisplays()
        case .status: RemoteControl.reply(status: manager.statusSnapshot, to: token)
        }
    }

    // MARK: - Login item

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Notifier.warn("""
            Could not change launch at login: \(error.localizedDescription) \
            It usually works when the app lives in /Applications. With ad-hoc \
            signing you have to re-enable it after every rebuild.
            """)
        }
    }
}
