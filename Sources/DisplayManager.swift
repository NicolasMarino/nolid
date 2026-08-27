//
//  DisplayManager.swift
//  NoLid
//
//  State logic: which display is the built-in one, when to turn it off, when
//  to bring it back, and the safety nets that keep at least one usable display
//  available at all times.
//

import AppKit

final class DisplayManager {

    static let shared = DisplayManager()

    // MARK: - Persisted preferences

    private enum Key {
        static let desiredOff = "builtInShouldBeOff"
        static let autoMode = "autoMode"
        static let lastBuiltInID = "lastBuiltInDisplayID"
        static let savedBrightness = "savedBuiltInBrightness"
        static let preferredMaster = "preferredMirrorMasterUUID"
        static let notifyOnChange = "notifyOnChange"
    }

    private let defaults: UserDefaults
    private let backend: DisplayBackend
    private let notices: NoticeSink

    /// Profiles keyed by set of monitors.
    let profiles: DisplayProfiles

    /// - Note: the defaults are injected so tests never touch the real
    ///   preference domain, and the backend so they never touch real hardware.
    init(backend: DisplayBackend = SystemDisplayBackend(),
         notices: NoticeSink = SystemNoticeSink(),
         defaults: UserDefaults = .standard) {
        self.backend = backend
        self.notices = notices
        self.defaults = defaults
        self.profiles = DisplayProfiles(defaults: defaults)
    }

    /// Called on the main thread whenever state changes, to refresh the menu.
    var onChange: (() -> Void)?

    /// Automatic mode: turn the built-in off as soon as externals are present.
    var autoMode: Bool {
        get { defaults.bool(forKey: Key.autoMode) }
        set {
            defaults.set(newValue, forKey: Key.autoMode)
            if newValue {
                recomputeDesiredFromTopology()
                // Without this the saved profile would keep winning on the next
                // topology change and automatic mode would appear to do nothing.
                rememberCurrentTopologyIfNeeded()
            }
            apply()
        }
    }

    /// What the user wants: `true` means built-in off. Persisted across launches.
    private var desiredOff: Bool {
        get { defaults.bool(forKey: Key.desiredOff) }
        set { defaults.set(newValue, forKey: Key.desiredOff) }
    }

    /// Post a notification whenever the built-in display flips state. Off by
    /// default: automatic mode is meant to be invisible, and a notification on
    /// every dock and undock would be noise rather than information.
    var notifyOnChange: Bool {
        get { defaults.bool(forKey: Key.notifyOnChange) }
        set {
            defaults.set(newValue, forKey: Key.notifyOnChange)
            lastAnnouncedOff = isBuiltInOff
        }
    }

    /// UUID of the monitor acting as master in the mirroring fallback.
    /// `nil` means whichever the system returns first.
    var preferredMasterUUID: String? {
        get { defaults.string(forKey: Key.preferredMaster) }
        set {
            defaults.set(newValue, forKey: Key.preferredMaster)
            // If already mirroring, rebuild the mirror against the new master.
            if usingMirrorFallback, let builtIn = builtInID {
                turnOn(builtIn)
                apply()
            } else {
                notifyChange()
            }
        }
    }

    /// Last state announced through `notifyOnChange`, so only real transitions
    /// are reported and a reconciliation loop cannot spam.
    private var lastAnnouncedOff: Bool?

    private var cachedBuiltIn: CGDirectDisplayID?
    private var lastExternalCount = -1
    private var usingMirrorFallback = false
    private var debounce: DispatchWorkItem?
    private var watchdog: Timer?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Queries

    /// Id of the built-in display. Cached because disabling it can make it
    /// vanish from the system lists, and we still need to re-enable it.
    var builtInID: CGDirectDisplayID? {
        if let live = backend.builtInDisplay() {
            if cachedBuiltIn != live {
                cachedBuiltIn = live
                defaults.set(Int(live), forKey: Key.lastBuiltInID)
            }
            return live
        }
        if let cachedBuiltIn { return cachedBuiltIn }
        let stored = defaults.integer(forKey: Key.lastBuiltInID)
        guard stored > 0 else { return nil }
        cachedBuiltIn = CGDirectDisplayID(stored)
        return cachedBuiltIn
    }

    var externalDisplays: [CGDirectDisplayID] {
        backend.activeDisplays().filter { !backend.isBuiltIn($0) }
    }

    /// Monitor that will host the mirror. Honours the user's choice while that
    /// monitor is still connected; otherwise falls back to the first available.
    var mirrorMaster: CGDirectDisplayID? {
        let externals = externalDisplays
        if let wanted = preferredMasterUUID,
           let match = externals.first(where: { backend.uuid($0) == wanted }) {
            return match
        }
        return externals.first
    }

    /// Observed state, not the desired one. Covers both methods: disconnected
    /// from the system, or mirroring another display in the fallback path.
    var isBuiltInOff: Bool {
        guard let id = builtInID else { return false }
        if !backend.activeDisplays().contains(id) { return true }
        return backend.isMirroringAnother(id)
    }

    var canTurnOffBuiltIn: Bool { !externalDisplays.isEmpty }

    var backendDescription: String {
        backend.supportsHardDisable
            ? "SkyLight (hard disable)"
            : "mirroring (public fallback)"
    }

    /// Profile key for the monitors connected right now.
    var topologyKey: String { DisplayProfiles.key(for: externalDisplays, using: backend) }

    /// Human-readable name of the current topology, for the menu.
    var topologyLabel: String { DisplayProfiles.label(for: externalDisplays, using: backend) }

    // MARK: - Lifecycle

    func start() {
        CGDisplayRegisterReconfigurationCallback(reconfigurationCallback, nil)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.apply() }
        }

        // In `.common` mode so the watchdog keeps running with a menu open or
        // a panel on screen — exactly when it is needed most.
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            self?.safetyCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer

        lastExternalCount = externalDisplays.count
        lastAnnouncedOff = isBuiltInOff
        adoptPreferenceForCurrentTopology()
        apply()
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        watchdog?.invalidate()
        watchdog = nil
        debounce?.cancel()
    }

    // MARK: - User actions

    func toggleBuiltIn() {
        setBuiltInOff(!isBuiltInOff)
    }

    /// Single entry point for "I want the built-in display off / on".
    /// Used by the menu, the global hotkey and the CLI.
    func setBuiltInOff(_ off: Bool) {
        if off {
            guard canTurnOffBuiltIn else {
                notices.warn("No active external monitors: the built-in display cannot be turned off.")
                return
            }
            notices.resetThrottle()
        }
        desiredOff = off
        rememberCurrentTopologyIfNeeded()
        apply()
    }

    /// Panic button: returns every display to a usable state.
    /// - Parameter resetPreference: `false` keeps the stored preference so it can
    ///   be reapplied on the next launch. Used when the app quits.
    /// - Note: it does not touch the saved profile. Panic is an emergency exit,
    ///   not a preference decision: if it wrote one, a single press would erase
    ///   what the user chose for this set of monitors.
    func enableAllDisplays(resetPreference: Bool = true) {
        if resetPreference { desiredOff = false }

        // A disabled built-in may not show up in `onlineDisplays()`, so the
        // cached id is added explicitly.
        var targets = Set(backend.onlineDisplays())
        if let cached = builtInID { targets.insert(cached) }
        for id in targets { backend.setEnabled(id, true) }

        // Only undo the mirror this app created, never one the user configured
        // on purpose.
        if usingMirrorFallback, let builtIn = builtInID {
            backend.setMirror(builtIn, of: nil)
            restoreBrightness()
        }
        usingMirrorFallback = false
        notifyChange()
    }

    // MARK: - Engine

    /// Drives the observed state towards the desired one. Idempotent.
    /// Exposed for tests: reconciles observed state with desired state.
    func apply() {
        guard let builtIn = builtInID else { notifyChange(); return }

        let shouldBeOff = desiredOff && canTurnOffBuiltIn

        if shouldBeOff {
            if !isBuiltInOff { turnOff(builtIn) }
        } else {
            // Unconditional: `turnOn` is idempotent and always undoes the mirror
            // and the brightness even when `isBuiltInOff` already reports false,
            // e.g. macOS tore the mirror set down itself on unplug.
            turnOn(builtIn)
        }
        notifyChange()
    }

    private func turnOff(_ builtIn: CGDirectDisplayID) {
        if backend.supportsHardDisable, backend.setEnabled(builtIn, false) {
            // The symbol can return success and do nothing. Only trust it when
            // the display genuinely left the active display list.
            if !backend.activeDisplays().contains(builtIn) {
                usingMirrorFallback = false
                notices.resetThrottle()
                return
            }
            backend.setEnabled(builtIn, true) // undo the failed attempt
        }

        guard let master = mirrorMaster else {
            desiredOff = false
            return
        }

        saveBrightness(of: builtIn)
        if backend.setMirror(builtIn, of: master) {
            usingMirrorFallback = true
            backend.setBrightness(builtIn, 0)
            notices.resetThrottle()
        } else {
            // Without this, `apply()` would retry every 1.2s in a loop.
            desiredOff = false
            notices.warn("Neither method could turn the built-in display off.")
        }
    }

    private func turnOn(_ builtIn: CGDirectDisplayID) {
        if usingMirrorFallback {
            backend.setMirror(builtIn, of: nil)
            restoreBrightness()
            usingMirrorFallback = false
        }
        if !backend.activeDisplays().contains(builtIn) {
            backend.setEnabled(builtIn, true)
        }
    }

    /// In automatic mode topology rules: externals present -> built-in off.
    private func recomputeDesiredFromTopology() {
        desiredOff = !externalDisplays.isEmpty
    }

    // MARK: - Profiles

    /// Decides which preference governs the monitors connected right now.
    ///
    /// Priority order: saved profile for this topology > automatic mode > the
    /// last global preference.
    private func adoptPreferenceForCurrentTopology() {
        if profiles.enabled, let remembered = profiles.desiredOff(for: topologyKey) {
            desiredOff = remembered
            return
        }
        if autoMode { recomputeDesiredFromTopology() }
    }

    /// Stores the user's decision for the current topology. Only with profiles
    /// enabled: otherwise the global preference remains the only one.
    private func rememberCurrentTopologyIfNeeded() {
        guard profiles.enabled else { return }
        profiles.remember(desiredOff, for: topologyKey)
    }

    /// Forgets the current topology's profile and returns to the default
    /// behaviour for this set of monitors.
    func forgetCurrentProfile() {
        profiles.forget(topologyKey)
        adoptPreferenceForCurrentTopology()
        apply()
    }

    // MARK: - Reacting to hardware changes

    fileprivate func scheduleReconcile() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Exposed for tests: simulates the debounced hardware-change reaction.
    func reconcile() {
        let count = externalDisplays.count
        let topologyChanged = count != lastExternalCount
        lastExternalCount = count

        // Note: `desiredOff` is left alone when there are no externals. `apply()`
        // already guarantees safety, and the preference survives unplugging.
        if topologyChanged { adoptPreferenceForCurrentTopology() }

        apply()
    }

    /// Periodic safety net: never end up without a usable display.
    /// Exposed for tests: one tick of the watchdog.
    func safetyCheck() {
        if backend.activeDisplays().isEmpty {
            if let builtIn = builtInID { turnOn(builtIn) }
            notifyChange()
            return
        }
        if externalDisplays.isEmpty, let builtIn = builtInID,
           isBuiltInOff || usingMirrorFallback {
            turnOn(builtIn)
            notifyChange()
        }
    }

    // MARK: - Brightness

    private func saveBrightness(of id: CGDirectDisplayID) {
        if let current = backend.brightness(id), current > 0.01 {
            defaults.set(Double(current), forKey: Key.savedBrightness)
        } else if defaults.object(forKey: Key.savedBrightness) == nil {
            defaults.set(0.6, forKey: Key.savedBrightness)
        }
    }

    private func restoreBrightness() {
        guard let id = builtInID else { return }
        let value = defaults.object(forKey: Key.savedBrightness) as? Double ?? 0.6
        backend.setBrightness(id, Float(value))
    }

    // MARK: - Notices

    private func notifyChange() {
        announceIfNeeded()
        if Thread.isMainThread { onChange?() }
        else { DispatchQueue.main.async { [weak self] in self?.onChange?() } }
    }

    /// Reports a genuine state transition, once, when the user asked for it.
    private func announceIfNeeded() {
        let off = isBuiltInOff
        defer { lastAnnouncedOff = off }
        guard notifyOnChange, let previous = lastAnnouncedOff, previous != off else { return }

        notices.inform(off
            ? "Built-in display off — \(backendDescription)."
            : "Built-in display back on.")
    }

    // MARK: - Snapshot for the CLI

    /// Serializable state, in property-list-compatible types so it can travel
    /// inside a distributed notification.
    var statusSnapshot: [String: Any] {
        let externals = externalDisplays
        return [
            "builtInOff": isBuiltInOff,
            "canTurnOff": canTurnOffBuiltIn,
            "externalCount": externals.count,
            "externalNames": externals.map { backend.name($0) },
            "method": backend.supportsHardDisable ? "skylight" : "mirroring",
            "methodDescription": backendDescription,
            "autoMode": autoMode,
            "profilesEnabled": profiles.enabled,
            "notifyOnChange": notifyOnChange,
            "topology": topologyLabel,
        ]
    }
}

// C callback: captures no context, it only references the global singleton.
private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    let interesting: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .enabledFlag, .disabledFlag, .setModeFlag, .desktopShapeChangedFlag
    ]
    guard !flags.intersection(interesting).isEmpty else { return }
    DispatchQueue.main.async { DisplayManager.shared.scheduleReconcile() }
}
