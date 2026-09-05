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
        static let mirrorFallback = "usingMirrorFallback"
        static let mirrorFallbackMaster = "usingMirrorFallbackMasterUUID"
        static let dimmed = "builtInDimmed"
        static let disabledExternals = "disabledExternalDisplays"
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

    /// `true` when the built-in is mirroring because *this app* put it there.
    ///
    /// Persisted on purpose. It is the only record of "the mirror is ours, tear
    /// it down"; if it lived in memory a crash would leave the panel mirrored at
    /// zero brightness with nothing left that knows to undo it. It is also the
    /// reason a mirror the user configured themselves is never touched, so it
    /// cannot be replaced by asking the hardware.
    private var usingMirrorFallback: Bool {
        get { defaults.bool(forKey: Key.mirrorFallback) }
        set { defaults.set(newValue, forKey: Key.mirrorFallback) }
    }

    /// UUID of the display we mirrored onto, recorded alongside the flag.
    ///
    /// "We are mirroring" is not enough to claim ownership. Someone who changes
    /// the mirror set in System Settings leaves the flag true and the mirror
    /// theirs; only the master identifies the arrangement this app actually
    /// built.
    private var mirrorFallbackMaster: String? {
        get { defaults.string(forKey: Key.mirrorFallbackMaster) }
        set { defaults.set(newValue, forKey: Key.mirrorFallbackMaster) }
    }

    /// `true` when *this app* set the built-in's brightness to zero.
    ///
    /// Deliberately separate from `usingMirrorFallback`, because the two
    /// obligations do not end at the same moment. Unplugging the master makes
    /// macOS tear our mirror down for us: the mirror is gone, the claim on it
    /// is correctly dropped — and the panel is still sitting at zero
    /// brightness, which only we know to undo. Folding both into one flag left
    /// the display active, unmirrored, and black.
    private var dimmedBuiltIn: Bool {
        get { defaults.bool(forKey: Key.dimmed) }
        set { defaults.set(newValue, forKey: Key.dimmed) }
    }

    // MARK: - Externals the user silenced

    /// An external the user deliberately turned off, and how to find it again.
    ///
    /// The UUID is the identity: `CGDirectDisplayID` is reassigned on every
    /// reconnect, so a preference keyed by it could never be matched twice.
    /// The id is kept anyway because a disabled display can leave the system
    /// lists entirely, and once it has, its UUID resolves to nothing — the same
    /// bind the built-in is in, solved the same way. The name is stored so the
    /// menu can still offer it back by something a human recognises.
    struct SilencedDisplay: Codable, Equatable {
        var uuid: String
        var lastID: UInt32
        var name: String
    }

    /// Externals turned off on purpose, keyed by UUID.
    ///
    /// Deliberately NOT merged with `desiredOff` into one set of displays.
    /// The two look alike and behave nothing alike: the built-in turns itself
    /// off by topology and is rescued automatically, while one of these is a
    /// standing instruction from the user that no watchdog may quietly undo.
    /// One representation for two obligations is exactly how the brightness
    /// was lost when a mirror went away.
    private(set) var silenced: [String: SilencedDisplay] {
        get {
            guard let data = defaults.data(forKey: Key.disabledExternals),
                  let decoded = try? JSONDecoder().decode(
                      [String: SilencedDisplay].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.disabledExternals)
        }
    }

    /// Drops the ownership claim when the hardware no longer matches it.
    ///
    /// Called on launch and on every hardware change, because both are moments
    /// when the mirror set can have become something we did not build: a reboot
    /// destroys it outright, and System Settings can rebuild it against another
    /// monitor entirely.
    private func reconcileMirrorOwnership() {
        guard usingMirrorFallback else { return }
        guard let builtIn = builtInID else { return }

        let source = backend.mirrorSource(of: builtIn)
        let stillOurs = source.map { current in
            // No recorded master means the claim predates this bookkeeping.
            // Mirroring at all is the most that can be honestly concluded.
            mirrorFallbackMaster.map { $0 == backend.uuid(current) } ?? true
        } ?? false

        if !stillOurs {
            usingMirrorFallback = false
            mirrorFallbackMaster = nil
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

    /// Held while any display is deliberately off.
    ///
    /// NoLid is an `LSUIElement` agent: no windows, no dock icon, and for long
    /// stretches no user interaction — the exact profile macOS App Naps most
    /// eagerly. A napped process gets its timers coalesced and deferred, and
    /// the watchdog is a timer. Every safety net in this file assumes it runs
    /// on time, and none of them can assert that about themselves.
    ///
    /// Scoped rather than switched off in Info.plist: while every display is
    /// on there is nothing to rescue, and an agent that refuses to nap for no
    /// reason is a bad citizen on someone's battery. Idle system sleep stays
    /// allowed — the point is to stay schedulable, not to keep the Mac awake.
    private var wakefulness: NSObjectProtocol?

    /// How many times an empty screen is attacked before waiting for a tick.
    let emptyScreenAttempts = 4

    /// How a retry is scheduled. Replaced in tests so the sequence runs inline
    /// instead of eight seconds at a time.
    var scheduleRetry: (@escaping () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func holdAwake(_ needed: Bool) {
        if needed, wakefulness == nil {
            wakefulness = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "A display is turned off and has to be recoverable")
        } else if !needed, let token = wakefulness {
            ProcessInfo.processInfo.endActivity(token)
            wakefulness = nil
        }
    }

    /// `true` when something is off that this app is on the hook to bring back.
    private var owesARecovery: Bool {
        desiredOff || !silenced.isEmpty || usingMirrorFallback || dimmedBuiltIn
    }

    private var cachedBuiltIn: CGDirectDisplayID?
    private var lastExternalCount = -1
    private var debounce: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
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

    /// `true` when turning `id` off would still leave something on screen.
    ///
    /// The single rule the whole feature rests on, and it is deliberately about
    /// *any* display rather than the built-in: "at least one other display stays
    /// active" is the invariant, and the built-in was only ever a special case
    /// of it. Evaluated live on every call, never cached, because the answer
    /// changes the moment a cable moves.
    func canDisable(_ id: CGDirectDisplayID) -> Bool {
        backend.activeDisplays().contains { $0 != id }
    }

    var canTurnOffBuiltIn: Bool {
        guard let builtIn = builtInID else { return false }
        return canDisable(builtIn)
    }

    /// Externals the system still lists, whether or not they are active.
    ///
    /// `externalDisplays` reports what is usable; this reports what is plugged
    /// in. A display we turned off can drop out of both lists, so anything the
    /// user has to be able to turn back on is carried by `silenced` instead.
    var connectedExternals: [CGDirectDisplayID] {
        backend.onlineDisplays().filter { !backend.isBuiltIn($0) }
    }

    /// `true` when this display is one the user silenced.
    func isSilenced(_ id: CGDirectDisplayID) -> Bool {
        guard let uuid = backend.uuid(id) else { return false }
        return silenced[uuid] != nil
    }

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

        // A strict dispatch source rather than a Timer on the run loop. Both
        // fire on the main queue, so nothing here becomes concurrent — but
        // `.strict` opts out of the timer coalescing the system applies to
        // background apps, and a watchdog that can be deferred is not one.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + 8, repeating: 8, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.safetyCheck() }
        timer.resume()
        watchdog = timer

        Log.state("started — hard disable: \(backend.supportsHardDisable), "
        + "active: \(backend.activeDisplays().count), "
        + "built-in off wanted: \(desiredOff)")

        lastExternalCount = externalDisplays.count
        lastAnnouncedOff = isBuiltInOff
        // The flag survives a crash on purpose, so it can outlive the mirror it
        // describes. Left stale it would authorise us to break a mirror the
        // user built themselves.
        reconcileMirrorOwnership()
        adoptPreferenceForCurrentTopology()
        apply()
    }

    func stop() {
        CGDisplayRemoveReconfigurationCallback(reconfigurationCallback, nil)
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        watchdog?.cancel()
        watchdog = nil
        holdAwake(false)
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

    /// Turns an external monitor off, or brings it back.
    ///
    /// The case this exists for: a monitor wired to the Mac on one input and to
    /// something else on another. Switch it to the other input and macOS never
    /// notices — the link on its own port stays up, so it keeps handing that
    /// screen windows you cannot see.
    ///
    /// Only the hard disable is used here, never the mirroring fallback. On the
    /// built-in the fallback is worth its awkwardness because there is no other
    /// way to quiet that panel. On an external it would mirror your other
    /// desktop onto a monitor you are using for something else, and add one more
    /// state that can be left half torn down. Refusing is the better answer.
    func setExternalOff(_ id: CGDirectDisplayID, _ off: Bool) {
        guard !backend.isBuiltIn(id) else { return }
        guard let uuid = backend.uuid(id) else {
            notices.warn("This monitor reports no stable identity, so NoLid "
                + "cannot reliably turn it back on. Refusing to turn it off.")
            return
        }

        guard off else { restore(uuid); return }

        guard backend.supportsHardDisable else {
            notices.warn("Turning an external monitor off needs the hard disable "
                + "this Mac does not support. Run `nolid doctor` for detail.")
            return
        }
        guard canDisable(id) else {
            notices.warn("That is the only display left: it cannot be turned off.")
            return
        }

        // Recorded before the attempt, not after. If the call succeeds and the
        // display drops out of every system list, this record is the only thing
        // left that knows the monitor exists and that we owe it a way back.
        var current = silenced
        current[uuid] = SilencedDisplay(uuid: uuid, lastID: id, name: backend.name(id))
        silenced = current

        if !disableExternal(id) {
            current.removeValue(forKey: uuid)
            silenced = current
            notices.warn("That monitor could not be turned off.")
        }
        notifyChange()
    }

    /// Brings a silenced monitor back and forgets the instruction.
    ///
    /// By UUID rather than by id, because a display that is off may be absent
    /// from every list the system will answer questions about.
    func restore(_ uuid: String) {
        defer { notifyChange() }
        guard let record = silenced[uuid] else { return }

        var recovered = false
        if let id = resolve(record) {
            backend.setEnabled(id, true)
            recovered = backend.activeDisplays().contains(id)
        }

        // The id we remembered can name nothing at all by now — renumbered while
        // it was gone, or moved to another port. Asking the system what exists
        // is the only thing left that can find it, and it is what the watchdog
        // already falls back to.
        if !recovered {
            for candidate in backend.onlineDisplays() {
                backend.setEnabled(candidate, true)
            }
            recovered = resolve(record).map {
                backend.activeDisplays().contains($0)
            } ?? false
        }

        // Forgotten either way. Left in place after a failure it would be
        // re-applied on the next tick, quietly turning off a monitor the user
        // had just asked to get back.
        var current = silenced
        current.removeValue(forKey: uuid)
        silenced = current

        if !recovered {
            notices.warn("\(record.name) could not be brought back. "
                + "Unplug and replug it, or run `nolid panic`.")
        }
    }

    /// The display a record points at, or `nil` when it cannot be named safely.
    private func resolve(_ record: SilencedDisplay) -> CGDirectDisplayID? {
        if let live = backend.onlineDisplays().first(
            where: { backend.uuid($0) == record.uuid }) {
            return live
        }
        // Falling back to the remembered id is only safe while it names nothing.
        // Ids are reused, and the UUID lookup above already failed, so an id
        // that *is* online now belongs to some other monitor. Turning that one
        // off instead is not a mistake that announces itself.
        let cached = CGDirectDisplayID(record.lastID)
        guard record.lastID != 0, !backend.onlineDisplays().contains(cached) else {
            return nil
        }
        return cached
    }

    /// Hard disable, verified against the active list rather than the return code.
    @discardableResult
    private func disableExternal(_ id: CGDirectDisplayID) -> Bool {
        guard backend.supportsHardDisable else { return false }
        backend.setEnabled(id, false)
        if backend.activeDisplays().contains(id) {
            backend.setEnabled(id, true)   // undo a call that reported success
            return false
        }
        return true
    }

    /// Panic button: returns every display to a usable state.
    /// - Parameter resetPreference: `false` keeps the stored preference so it can
    ///   be reapplied on the next launch. Used when the app quits.
    /// - Note: it does not touch the saved profile. Panic is an emergency exit,
    ///   not a preference decision: if it wrote one, a single press would erase
    ///   what the user chose for this set of monitors.
    /// - Returns: `true` once at least one display is verified active. The CLI's
    ///   own recovery path has always checked this; the in-app panic button
    ///   returning silently was the weaker of the two.
    @discardableResult
    func enableAllDisplays(resetPreference: Bool = true) -> Bool {
        if resetPreference {
            desiredOff = false
            // Cleared, not just overridden. Panic that left these in place would
            // re-apply them on the very next tick, so the button would appear to
            // do nothing on exactly the monitor the user was asking about.
            silenced = [:]
        }

        // A disabled built-in may not show up in `onlineDisplays()`, so the
        // cached id is added explicitly.
        var targets = Set(backend.onlineDisplays())
        if let cached = builtInID { targets.insert(cached) }
        for id in targets { backend.setEnabled(id, true) }

        // Only undo the mirror this app created, never one the user configured
        // on purpose.
        let wasOurMirror = usingMirrorFallback
        if wasOurMirror, let builtIn = builtInID {
            backend.setMirror(builtIn, of: nil)
            if !backend.isMirroringAnother(builtIn) {
                usingMirrorFallback = false
                mirrorFallbackMaster = nil
            }
        } else {
            usingMirrorFallback = false
            mirrorFallbackMaster = nil
        }
        if dimmedBuiltIn { restoreBrightness() }

        // A mirrored display still counts as "active", so the display list alone
        // cannot tell recovery from a panel left mirroring at zero brightness.
        // The CLI's recovery path has always checked both; this is the parity
        // the doc comment above claims.
        var recovered = !backend.activeDisplays().isEmpty
        if recovered, wasOurMirror, let builtIn = builtInID,
           backend.isMirroringAnother(builtIn) {
            recovered = false
        }
        if !recovered {
            notices.warn("No display could be restored. From another machine: "
                + "`ssh` in and run `nolid panic`.")
        }
        notifyChange()
        return recovered
    }

    // MARK: - Engine

    /// Drives the observed state towards the desired one. Idempotent.
    /// Exposed for tests: reconciles observed state with desired state.
    func apply() {
        applySilenced()
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

    /// Re-asserts every standing instruction to keep an external off.
    ///
    /// Runs on every tick because macOS re-enables a display whenever it feels
    /// like it: a reconnect, a wake, a resolution change. The instruction has to
    /// outlive those, or switching the monitor back to the Mac's input would be
    /// the only thing that ever undid it.
    private func applySilenced() {
        let records = silenced
        guard !records.isEmpty else { return }

        for (uuid, record) in records {
            guard let id = resolve(record) else { continue }
            if backend.isBuiltIn(id) {
                // Never this path. The built-in has its own policy, its own
                // watchdog and its own way back; a stale record claiming it
                // would fight all three.
                var current = silenced
                current.removeValue(forKey: uuid)
                silenced = current
                continue
            }
            guard backend.activeDisplays().contains(id) else { continue }
            // The invariant wins over the instruction, every time. A monitor
            // the user silenced yesterday does not get to be the reason there
            // is nothing on screen today.
            guard canDisable(id) else { continue }
            disableExternal(id)
        }
    }

    private func turnOff(_ builtIn: CGDirectDisplayID) {
        if backend.supportsHardDisable, backend.setEnabled(builtIn, false) {
            // The symbol can return success and do nothing. Only trust it when
            // the display genuinely left the active display list.
            if !backend.activeDisplays().contains(builtIn) {
                usingMirrorFallback = false
                notices.resetThrottle()
                Log.state("built-in off via hard disable — id \(builtIn)")
                return
            }
            backend.setEnabled(builtIn, true) // undo the failed attempt
        }

        guard let master = mirrorMaster else {
            abandonDesiredOff("No monitor available to mirror onto: "
                + "the built-in display cannot be turned off.")
            return
        }

        saveBrightness(of: builtIn)
        if backend.setMirror(builtIn, of: master) {
            usingMirrorFallback = true
            mirrorFallbackMaster = backend.uuid(master)
            if backend.setBrightness(builtIn, 0) { dimmedBuiltIn = true }
            notices.resetThrottle()
        } else {
            abandonDesiredOff("Neither method could turn the built-in display off.")
        }
    }

    /// Gives up on turning the built-in off, and makes sure nothing on disk
    /// keeps asking for it.
    ///
    /// Clearing `desiredOff` alone stops `apply()` retrying every 1.2s, but a
    /// profile saved a moment earlier by `setBuiltInOff` would still say "off"
    /// for this set of monitors and replay the same failing sequence on every
    /// future reconnect.
    private func abandonDesiredOff(_ reason: String) {
        desiredOff = false
        if profiles.enabled { profiles.remember(false, for: topologyKey) }
        notices.warn(reason)
    }

    /// Brings the built-in back. Idempotent.
    ///
    /// - Returns: `true` only once the display is verified usable. The way back
    ///   is checked as suspiciously as the way out: the same symbol that can
    ///   report a successful disable and do nothing can do it on re-enable, and
    ///   a silent failure here is the one outcome this whole app exists to
    ///   prevent.
    @discardableResult
    private func turnOn(_ builtIn: CGDirectDisplayID) -> Bool {
        let wasOurMirror = usingMirrorFallback
        if wasOurMirror {
            backend.setMirror(builtIn, of: nil)
            // The flag is cleared only once the mirror is verifiably gone.
            // Clearing it on a failed attempt would be worse than not trying:
            // the next call would read "not ours", skip the undo entirely and
            // report success, with the panel still mirrored at zero brightness.
            if !backend.isMirroringAnother(builtIn) {
                usingMirrorFallback = false
                mirrorFallbackMaster = nil
            }
        }
        // Unconditional, and after the mirror rather than inside it. A panel we
        // dimmed has to be brought back whether the mirror is still ours, was
        // torn down by macOS on unplug, or was never involved at all.
        if dimmedBuiltIn { restoreBrightness() }
        if !backend.activeDisplays().contains(builtIn) {
            backend.setEnabled(builtIn, true)
        }

        // Only our own mirror counts as a failure to undo. One the user set up
        // is a legitimate resting state, not something left half-torn-down.
        let active = backend.activeDisplays().contains(builtIn)
        let mirrorStuck = wasOurMirror && backend.isMirroringAnother(builtIn)
        guard active, !mirrorStuck else {
            Log.recoveryFailed(builtIn: builtIn,
                               online: backend.onlineDisplays().count,
                               active: backend.activeDisplays().count)
            notices.warn("The built-in display could not be turned back on. "
                + "Run `nolid panic`, or connect an external monitor.")
            return false
        }
        return true
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
        reconcileMirrorOwnership()

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
            // Nothing on screen is not a state to be surgical in. `turnOn`
            // targets one display: the built-in, by an id that was cached
            // before it was disabled. If that id no longer names anything —
            // renumbered across a sleep, a dock, an unplug — or if the private
            // symbol simply refuses it, every tick retries the same dead call
            // and the watchdog spins on a black screen forever.
            //
            // The sweep is the only thing left that can find a panel whose id
            // moved, because it asks the system what exists instead of
            // remembering what used to. The preference is kept: this is a
            // rescue, not the user changing their mind.
            rescueEmptyScreen(attempt: 1)
            return
        }
        // `dimmedBuiltIn` belongs here for the same reason it exists: a panel
        // left dark reports itself active and unmirrored, so every other test in
        // this method calls it healthy.
        if externalDisplays.isEmpty, let builtIn = builtInID,
           isBuiltInOff || usingMirrorFallback || dimmedBuiltIn {
            turnOn(builtIn)
            notifyChange()
        }
    }

    /// Nothing on screen. Tries hard, immediately, and again shortly after.
    ///
    /// The previous version made one attempt and waited for the next tick.
    /// Eight seconds is a long time to stare at nothing, and it is only eight
    /// seconds if the timer fires on schedule — which is exactly the assumption
    /// that cannot be checked from inside. At this moment nothing else this app
    /// does matters, so it stops being polite about it.
    private func rescueEmptyScreen(attempt: Int) {
        Log.emptyScreen(attempt: attempt, of: emptyScreenAttempts)

        if let builtIn = builtInID, turnOn(builtIn) {
            Log.recovered("built-in", active: backend.activeDisplays().count)
            notifyChange()
            return
        }
        if enableAllDisplays(resetPreference: false) {
            Log.recovered("sweep", active: backend.activeDisplays().count)
            return
        }

        guard attempt < emptyScreenAttempts else {
            Log.recoveryFailed(builtIn: builtInID,
                               online: backend.onlineDisplays().count,
                               active: backend.activeDisplays().count)
            notifyChange()
            return
        }
        scheduleRetry { [weak self] in self?.rescueEmptyScreen(attempt: attempt + 1) }
    }

    // MARK: - Brightness

    private func saveBrightness(of id: CGDirectDisplayID) {
        if let current = backend.brightness(id), current > 0.01 {
            defaults.set(Double(current), forKey: Key.savedBrightness)
        } else if defaults.object(forKey: Key.savedBrightness) == nil {
            defaults.set(0.6, forKey: Key.savedBrightness)
        }
    }

    /// Returns the built-in to the brightness it had before we dimmed it.
    ///
    /// The debt is cleared only once the hardware accepted the new value: a
    /// refused call that still marked it repaid would leave the panel dark with
    /// nothing left that knows to try again.
    private func restoreBrightness() {
        guard let id = builtInID else { return }
        let value = defaults.object(forKey: Key.savedBrightness) as? Double ?? 0.6
        if backend.setBrightness(id, Float(value)) { dimmedBuiltIn = false }
    }

    // MARK: - Notices

    private func notifyChange() {
        // Re-evaluated on every state change rather than at the two obvious
        // call sites, because "something is off" is reached by more paths than
        // anyone remembers: the menu, the hotkey, the CLI, automatic mode, a
        // profile adopted on reconnect.
        holdAwake(owesARecovery)
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
            "silencedCount": silenced.count,
            "silencedNames": silenced.values.map(\.name).sorted(),
        ]
    }
}

// C callback: captures no context, it only references the global singleton.
private let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    // The mirror flags matter as much as the rest: the mirroring fallback is one
    // of the two ways the built-in gets turned off, so a mirror set torn down or
    // rebuilt out-of-band is a state change we have to reconcile against.
    let interesting: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
        .setModeFlag, .desktopShapeChangedFlag, .mirrorFlag, .unMirrorFlag
    ]
    guard !flags.intersection(interesting).isEmpty else { return }
    DispatchQueue.main.async { DisplayManager.shared.scheduleReconcile() }
}
