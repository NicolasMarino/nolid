//
//  main.swift
//  NoLid tests
//
//  A plain executable, no XCTest and no Package.swift, to match the rest of the
//  project: `swiftc`, no dependencies, nothing to install. Exits non-zero on
//  the first failing expectation so CI can gate on it.
//
//  What is worth testing here is the safety machinery. Everything else in NoLid
//  is either a thin forwarder or AppKit wiring; the state machine is the part
//  that can silently leave someone staring at a black screen.
//

import CoreGraphics
import Foundation

// MARK: - Harness

var passed = 0
var failures: [String] = []
private var currentTest = ""

func test(_ name: String, _ body: () -> Void) {
    currentTest = name
    body()
}

func expect(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
    } else {
        failures.append("\(currentTest): \(message)")
    }
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    expect(actual == expected, "\(message) — expected \(expected), got \(actual)")
}

/// A manager wired to fakes, with a preference domain of its own so a test run
/// can never disturb the installed app's settings.
func makeManager(
    externals: [CGDirectDisplayID] = [],
    configure: (FakeDisplayBackend) -> Void = { _ in }
) -> (DisplayManager, FakeDisplayBackend, RecordingNoticeSink, UserDefaults) {
    let suite = "dev.nolid.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let backend = FakeDisplayBackend()
    backend.online = [1] + externals
    configure(backend)

    let notices = RecordingNoticeSink()
    let manager = DisplayManager(backend: backend, notices: notices, defaults: defaults)
    return (manager, backend, notices, defaults)
}

// MARK: - Safety net: never without a display

test("refuses to turn the built-in off when it is the only display") {
    let (manager, backend, notices, _) = makeManager()

    manager.setBuiltInOff(true)

    expect(manager.isBuiltInOff, false, "built-in must stay on")
    expect(backend.activeDisplays().contains(1), "built-in must stay active")
    expect(notices.warnings.count, 1, "the refusal must be reported")
}

test("watchdog restores the built-in when nothing is active") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    backend.hardDisabled = [1, 2]   // however we got here, this is unusable

    manager.safetyCheck()

    expect(backend.activeDisplays().contains(1), "watchdog must bring the built-in back")
}

test("watchdog restores the built-in when the last external is unplugged") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)
    expect(manager.isBuiltInOff, "precondition: built-in is off")

    backend.unplugExternals()
    manager.safetyCheck()

    expect(backend.activeDisplays().contains(1), "built-in must come back")
    expect(backend.isMirroringAnother(1), false, "the mirror must be undone")
}

test("reconcile brings the built-in back when the topology loses its externals") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)

    backend.unplugExternals()
    manager.reconcile()

    expect(manager.isBuiltInOff, false, "built-in must be usable again")
}

// MARK: - The two methods

test("hard disable removes the built-in from the active list") {
    let (manager, backend, _, _) = makeManager(externals: [2])

    manager.setBuiltInOff(true)

    expect(backend.activeDisplays().contains(1), false, "built-in must be gone")
    expect(backend.isMirroringAnother(1), false, "the fallback must not be used")
}

test("a symbol that returns success without working falls back to mirroring") {
    let (manager, backend, _, _) = makeManager(externals: [2]) { $0.hardDisableLies = true }

    manager.setBuiltInOff(true)

    expect(manager.isBuiltInOff, "the built-in must end up off by some method")
    expect(backend.isMirroringAnother(1), "the mirroring fallback must take over")
    expect(backend.mirrors[1], 2, "it must mirror the external")
    expect(backend.brightnessValues[1], 0, "and drop the backlight to zero")
    expect(backend.activeDisplays().contains(1), "the panel stays active under the fallback")
}

test("a rejected hard disable also falls back") {
    let (manager, backend, _, _) = makeManager(externals: [2]) { $0.hardDisableRejects = true }

    manager.setBuiltInOff(true)

    expect(backend.isMirroringAnother(1), "the fallback must take over")
}

test("when both methods fail the built-in stays usable and the user is told") {
    let (manager, backend, notices, _) = makeManager(externals: [2]) {
        $0.hardDisableLies = true
        $0.mirrorFails = true
    }

    manager.setBuiltInOff(true)

    expect(manager.isBuiltInOff, false, "the built-in must stay usable")
    expect(backend.activeDisplays().contains(1), "and stay active")
    expect(notices.warnings.count, 1, "the failure must be reported")

    // Without resetting the intent here, apply() would retry forever.
    manager.apply()
    expect(notices.warnings.count, 1, "and must not be reported on a loop")
}

test("turning the built-in back on undoes the mirror and restores brightness") {
    let (manager, backend, _, _) = makeManager(externals: [2]) { $0.hardDisableLies = true }
    backend.brightnessValues[1] = 0.8

    manager.setBuiltInOff(true)
    expect(backend.brightnessValues[1], 0, "precondition: backlight down")

    manager.setBuiltInOff(false)

    expect(backend.isMirroringAnother(1), false, "the mirror must be undone")
    expect(backend.brightnessValues[1], 0.8, "the previous brightness must come back")
}

// MARK: - Mirror master

test("the preferred mirror master is honoured") {
    let (manager, backend, _, _) = makeManager(externals: [2, 3]) { $0.hardDisableLies = true }
    manager.preferredMasterUUID = "uuid-3"

    manager.setBuiltInOff(true)

    expect(backend.mirrors[1], 3, "must mirror the chosen monitor, not the first one")
}

test("an unplugged preferred master falls back to whatever is left") {
    let (manager, backend, _, _) = makeManager(externals: [2]) { $0.hardDisableLies = true }
    manager.preferredMasterUUID = "uuid-99"   // never connected

    manager.setBuiltInOff(true)

    expect(backend.mirrors[1], 2, "must fall back instead of giving up")
}

// MARK: - Profiles

test("profile keys ignore plug order") {
    let backend = FakeDisplayBackend()
    expect(DisplayProfiles.key(for: [2, 3], using: backend),
           DisplayProfiles.key(for: [3, 2], using: backend),
           "the same pair of monitors must produce one key")
}

test("a saved profile wins over automatic mode") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.profiles.enabled = true
    manager.autoMode = true

    // The user overrides automatic mode for this particular setup.
    manager.setBuiltInOff(false)
    expect(manager.isBuiltInOff, false, "precondition: built-in on")

    // Unplug and replug the same monitor.
    backend.unplugExternals()
    manager.reconcile()
    backend.connect(2)
    manager.reconcile()

    expect(manager.isBuiltInOff, false, "the saved profile must survive the round trip")
}

test("automatic mode applies when no profile was saved for this topology") {
    let (manager, _, _, _) = makeManager(externals: [2])
    manager.profiles.enabled = true
    manager.autoMode = true

    manager.reconcile()

    expect(manager.isBuiltInOff, "automatic mode must turn the built-in off")
}

test("enabling automatic mode records it, so a topology change cannot revert it") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.profiles.enabled = true

    manager.setBuiltInOff(false)     // saves "built-in on" for this topology
    manager.autoMode = true          // user changes their mind
    expect(manager.isBuiltInOff, "precondition: automatic mode turned it off")

    backend.unplugExternals()
    manager.reconcile()
    backend.connect(2)
    manager.reconcile()

    expect(manager.isBuiltInOff, "the stale profile must not win back")
}

test("the panic button does not overwrite the saved profile") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.profiles.enabled = true
    manager.setBuiltInOff(true)      // saves "built-in off" for this topology

    manager.enableAllDisplays()      // emergency exit, not a preference change

    backend.unplugExternals()
    manager.reconcile()
    backend.connect(2)
    manager.reconcile()

    expect(manager.isBuiltInOff, "the profile the user chose must still apply")
}

// MARK: - Hotkey configuration

test("the default hotkey survives a coding round trip") {
    let suite = "dev.nolid.tests.hotkey.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    expect(HotKeyConfig.load(from: defaults), .default, "an empty domain must yield the default")

    let stored = HotKeyConfig.default
    stored.save(to: defaults)
    expect(HotKeyConfig.load(from: defaults), stored, "a saved hotkey must come back intact")

    HotKeyConfig.reset(in: defaults)
    expect(HotKeyConfig.load(from: defaults), .default, "reset must restore the default")
}

// MARK: - The doctor verdict

/// The probe decides on its own; these do not need a DisplayManager.
func makeProbe(externals: [CGDirectDisplayID] = [2],
               configure: (FakeDisplayBackend) -> Void = { _ in }) -> (CapabilityProbe, FakeDisplayBackend) {
    let backend = FakeDisplayBackend()
    backend.online = [1] + externals
    configure(backend)
    return (CapabilityProbe(backend: backend), backend)
}

test("the probe reports a working hard disable and puts the panel back") {
    let (probe, backend) = makeProbe()

    let result = probe.run(builtIn: 1, enabled: true, appReportsOff: false)

    expect(result.outcome, .hardDisableWorks, "the disable really worked")
    expect(backend.activeDisplays().contains(1), "and the panel must be back")
}

test("the probe catches a symbol that reports success and does nothing") {
    let (probe, backend) = makeProbe { $0.hardDisableLies = true }

    let result = probe.run(builtIn: 1, enabled: true, appReportsOff: false)

    expect(result.outcome, .reportsSuccessButDoesNothing, "a lying symbol must be named")
    expect(backend.activeDisplays().contains(1), "the panel stays usable")
}

test("the probe reports a rejected call") {
    let (probe, _) = makeProbe { $0.hardDisableRejects = true }
    expect(probe.run(builtIn: 1, enabled: true, appReportsOff: false).outcome, .callRejected,
           "a refusal is not the same as a lie")
}

test("the probe reports a missing symbol without touching anything") {
    let (probe, backend) = makeProbe { $0.supportsHardDisable = false }

    let result = probe.run(builtIn: 1, enabled: true, appReportsOff: false)

    expect(result.outcome, .symbolUnavailable, "nothing to probe")
    expect(backend.setEnabledCalls.isEmpty, "and nothing should have been attempted")
}

test("the probe refuses to run without an external monitor") {
    let (probe, backend) = makeProbe(externals: [])

    let result = probe.run(builtIn: 1, enabled: true, appReportsOff: false)

    expect(result.outcome, .skipped, "probing the only display would black it out")
    expect(backend.setEnabledCalls.isEmpty, "and must not be attempted")
}

test("the probe stands down when NoLid already turned the panel off") {
    let (probe, backend) = makeProbe()
    expect(probe.run(builtIn: 1, enabled: true, appReportsOff: true).outcome, .skipped,
           "no point probing a display that is already off")
    expect(backend.setEnabledCalls.isEmpty, "and nothing should have been attempted")
}

test("--no-probe skips without claiming a verdict") {
    let (probe, _) = makeProbe()
    let result = probe.run(builtIn: 1, enabled: false, appReportsOff: false)

    expect(result.outcome, .skipped, "asked not to probe")
    expect(result.verdict.contains("does not prove"), "the verdict must stay honest")
}

// MARK: - URL scheme

test("nolid:// URLs map to commands, in both spellings") {
    expect(RemoteControl.Command(url: URL(string: "nolid://toggle")!), .toggle, "host form")
    expect(RemoteControl.Command(url: URL(string: "nolid:///panic")!), .panic, "path form")
    expect(RemoteControl.Command(url: URL(string: "NOLID://ON")!), .on, "case must not matter")
}

test("URLs that are not ours, or name nothing we do, are ignored") {
    expect(RemoteControl.Command(url: URL(string: "nolid://frobnicate")!) == nil,
           "an unknown verb must not resolve")
    expect(RemoteControl.Command(url: URL(string: "https://example.com/toggle")!) == nil,
           "another scheme must not resolve")
}

// MARK: - Notices about state changes

test("change notices are off by default") {
    let (manager, _, notices, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)
    expect(notices.infos.isEmpty, "nothing should be announced unless asked")
}

test("change notices report transitions once, not on every pass") {
    let (manager, _, notices, _) = makeManager(externals: [2])
    manager.notifyOnChange = true

    manager.setBuiltInOff(true)
    expect(notices.infos.count, 1, "the transition must be announced")

    manager.apply()
    manager.apply()
    expect(notices.infos.count, 1, "a reconciliation pass is not a transition")

    manager.setBuiltInOff(false)
    expect(notices.infos.count, 2, "coming back is a transition too")
}

// MARK: - Snapshot the CLI depends on

test("the status snapshot reports what the CLI prints") {
    let (manager, _, _, _) = makeManager(externals: [2, 3])
    manager.setBuiltInOff(true)

    let snapshot = manager.statusSnapshot

    expect(snapshot["builtInOff"] as? Bool, true, "built-in state")
    expect(snapshot["canTurnOff"] as? Bool, true, "externals present")
    expect(snapshot["externalCount"] as? Int, 2, "external count")
    expect(snapshot["method"] as? String, "skylight", "method identifier")
    expect((snapshot["externalNames"] as? [String])?.count, 2, "one name per external")
    for key in ["autoMode", "profilesEnabled", "notifyOnChange", "topology", "methodDescription"] {
        expect(snapshot[key] != nil, "snapshot must carry \(key)")
    }
}

test("the topology label lists monitors in a stable order") {
    let backend = FakeDisplayBackend()
    expect(DisplayProfiles.label(for: [3, 2], using: backend),
           DisplayProfiles.label(for: [2, 3], using: backend),
           "plug order must not change the label")
    expect(DisplayProfiles.label(for: [], using: backend), "Built-in display only",
           "no externals has its own label")
}

// MARK: - Profile bookkeeping

test("profiles can be forgotten one at a time and all at once") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    manager.profiles.enabled = true

    manager.setBuiltInOff(true)
    let key = manager.topologyKey
    expect(manager.profiles.desiredOff(for: key), true, "the decision must be stored")
    expect(manager.profiles.count, 1, "one profile so far")

    manager.forgetCurrentProfile()
    expect(manager.profiles.desiredOff(for: key) == nil, "forgetting must clear it")

    manager.setBuiltInOff(true)
    backend.connect(3)
    manager.reconcile()
    manager.setBuiltInOff(false)
    expect(manager.profiles.count, 2, "a different topology is a different profile")

    manager.profiles.forgetAll()
    expect(manager.profiles.count, 0, "and all of them can go at once")
}

// MARK: - Identity of the built-in display

test("the built-in is still found after it drops off the system lists") {
    let (manager, backend, _, _) = makeManager(externals: [2])
    expect(manager.builtInID, 1, "precondition: found while connected")

    // Hard disable can take the panel out of the lists entirely. Losing track
    // of it here would mean losing the ability to turn it back on.
    backend.online.removeAll { $0 == 1 }

    expect(manager.builtInID, 1, "the cached id must survive")
}

test("toggling twice returns to where it started") {
    let (manager, _, _, _) = makeManager(externals: [2])
    let before = manager.isBuiltInOff

    manager.toggleBuiltIn()
    expect(manager.isBuiltInOff, !before, "first toggle must flip it")
    manager.toggleBuiltIn()
    expect(manager.isBuiltInOff, before, "second toggle must flip it back")
}

// MARK: - CLI argument parsing

test("every spelling of help is recognised") {
    for spelling in ["--help", "-h", "help"] {
        expect(CommandLineOptions(arguments: [spelling]).wantsHelp,
               "\(spelling) must ask for help")
    }
    // The bug this exists for: filtering out `--` options before looking for
    // the verb ate --help, so asking for help exited 2 with usage on stderr.
    expect(CommandLineOptions(arguments: ["--help"]).command == nil,
           "help is not a command to dispatch")
}

test("the verb is found regardless of where the options sit") {
    expect(CommandLineOptions(arguments: ["doctor", "--json"]).command, "doctor", "options after")
    expect(CommandLineOptions(arguments: ["--json", "doctor"]).command, "doctor", "options before")
    expect(CommandLineOptions(arguments: []).command == nil, "no arguments means no verb")
}

test("flags are read wherever they appear") {
    let options = CommandLineOptions(arguments: ["doctor", "--json", "--no-probe"])
    expect(options.wantsJSON, "--json must be seen")
    expect(options.skipProbe, "--no-probe must be seen")
    expect(options.unknownOptions.isEmpty, "known flags are not unknown")
}

test("an unknown option is reported rather than silently dropped") {
    let options = CommandLineOptions(arguments: ["status", "--jsonn"])
    expect(options.unknownOptions, ["--jsonn"], "a typo must not pass for the real flag")
    expect(options.command, "status", "the verb is still found")
}

// MARK: - The way back is verified as hard as the way out

test("a failed re-enable is reported instead of passing silently") {
    let (manager, backend, notices, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)
    expect(manager.isBuiltInOff, "precondition: the built-in is off")

    backend.reEnableFails = true
    manager.setBuiltInOff(false)

    expect(backend.activeDisplays().contains(1), false, "the fake must keep it disabled")
    expect(notices.warnings.isEmpty, false, "silence here is the bug: it must warn")
}

test("the watchdog reports being unable to bring the last display back") {
    let (manager, backend, notices, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)

    // The external goes away while the built-in is hard-disabled, and the way
    // back is broken: zero active displays, the worst state the app can reach.
    backend.reEnableFails = true
    backend.unplugExternals()
    manager.safetyCheck()

    expect(backend.activeDisplays().isEmpty, "precondition: no display is active")
    expect(notices.warnings.isEmpty, false, "the user must be told, not left guessing")
}

test("a mirror that cannot be undone counts as a failure") {
    let (manager, backend, notices, _) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)
    expect(backend.isMirroringAnother(1), "precondition: the fallback mirrored it")

    backend.unmirrorFails = true
    manager.setBuiltInOff(false)

    expect(backend.isMirroringAnother(1), "the fake must keep it mirrored")
    expect(notices.warnings.isEmpty, false, "a stuck mirror is not a success")
}

test("the panic button reports when it recovers nothing") {
    let (manager, backend, notices, _) = makeManager(externals: [2])
    manager.setBuiltInOff(true)

    backend.reEnableFails = true
    backend.unplugExternals()
    let recovered = manager.enableAllDisplays()

    expect(recovered, false, "panic must admit it failed")
    expect(notices.warnings.isEmpty, false, "and say so out loud")
}

// MARK: - The mirror fallback survives a crash

test("the mirror fallback is remembered across a process restart") {
    let (manager, backend, _, defaults) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)
    expect(backend.isMirroringAnother(1), "precondition: mirrored by the fallback")

    // A crash: no teardown runs, a new manager comes up on the same defaults
    // and the same hardware.
    let reborn = DisplayManager(backend: backend, notices: RecordingNoticeSink(),
                                defaults: defaults)
    reborn.enableAllDisplays()

    expect(backend.isMirroringAnother(1), false,
           "panic after a crash must still undo our own mirror")
}

test("a mirror the user set up themselves is never torn down") {
    let (_, backend, _, defaults) = makeManager(externals: [2])
    // Nothing in NoLid created this one.
    backend.setMirror(1, of: 2)

    let manager = DisplayManager(backend: backend, notices: RecordingNoticeSink(),
                                 defaults: defaults)
    manager.start()
    manager.enableAllDisplays()

    expect(backend.isMirroringAnother(1), "someone else's mirror is not ours to undo")
    manager.stop()
}

test("a stale fallback flag is cleared when the hardware disagrees") {
    let (manager, backend, _, defaults) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)
    manager.setBuiltInOff(false)   // the user wants it on again
    manager.stop()

    // A reboot: the mirror set is gone, but the flag survived on disk. Put it
    // back by hand, which is the state a crash mid-mirror would leave behind.
    defaults.set(true, forKey: "usingMirrorFallback")
    backend.mirrors.removeAll()

    let reborn = DisplayManager(backend: backend, notices: RecordingNoticeSink(),
                                defaults: defaults)
    reborn.start()

    // With the flag still set, this next mirror would look like ours to undo.
    backend.setMirror(1, of: 2)
    reborn.enableAllDisplays()

    expect(backend.isMirroringAnother(1), "a stale flag must not authorise breaking it")
    reborn.stop()
}

// MARK: - A failure must not be persisted as a preference

test("failing to turn off does not leave a profile asking to retry forever") {
    let (manager, _, notices, _) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
        $0.mirrorFails = true
    }
    manager.profiles.enabled = true

    manager.setBuiltInOff(true)

    expect(manager.isBuiltInOff, false, "it could not be turned off")
    expect(manager.profiles.desiredOff(for: manager.topologyKey), false,
           "the profile must not keep asking for a state that cannot be reached")
    expect(notices.warnings.isEmpty, false, "and the failure must be reported")
}

test("losing the last monitor mid-operation is reported, not swallowed") {
    let (manager, backend, notices, _) = makeManager(externals: [2]) {
        // Success on the way out, nothing actually disabled: the run continues
        // into the mirroring fallback, which is where the race lives.
        $0.hardDisableLies = true
    }

    // The external is yanked between the check that said "you may turn it off"
    // and the read that looks for something to mirror onto. Unreachable from a
    // single-threaded test any other way, and entirely reachable on a desk.
    backend.afterSetEnabled = { _, enabled in
        if enabled { backend.unplugExternals() }
    }

    manager.setBuiltInOff(true)

    expect(manager.isBuiltInOff, false, "there was nothing left to mirror onto")
    expect(notices.warnings.isEmpty, false, "the README promises failures always notify")
}

// MARK: - Stable identity

test("a display with no UUID does not get a key that changes on reconnect") {
    let anonymous = FakeDisplayBackend()
    anonymous.online = [1, 2]
    anonymous.uuidsUnavailable = true

    let first = DisplayProfiles.key(for: [2], using: anonymous)
    // Same physical monitor, new id after a reconnect.
    anonymous.online = [1, 77]
    let second = DisplayProfiles.key(for: [77], using: anonymous)

    expect(first, second, "a key built from the volatile id could never match again")
}

test("the probe reports a failed restore separately from the verdict") {
    let backend = FakeDisplayBackend()
    backend.online = [1, 2]
    backend.reEnableFails = true

    let result = CapabilityProbe(backend: backend).run(builtIn: 1, enabled: true,
                                                       appReportsOff: false)

    expect(result.restored, false, "the screen is still dark and that must be visible")
    expect(result.outcome, .hardDisableWorks, "the capability answer is still true")
    expect(result.detail.contains("came back"), false,
           "it must not claim a return that did not happen")
}

test("a clean probe reports the display restored") {
    let backend = FakeDisplayBackend()
    backend.online = [1, 2]

    let result = CapabilityProbe(backend: backend).run(builtIn: 1, enabled: true,
                                                       appReportsOff: false)

    expect(result.restored, "nothing failed, so nothing to warn about")
    expect(backend.activeDisplays().contains(1), "and the panel is back")
}

// MARK: - The CLI and the app agree on the protocol

test("the CLI speaks the same channel names as the app") {
    expect(RemoteControl.prefix, "dev.nolid.command.", "the command prefix is part of the contract")
    expect(RemoteControl.replyPrefix, "dev.nolid.status.", "so is the reply channel")
}

test("each request gets its own reply channel") {
    let a = RemoteControl.replyName(for: "aaa")
    let b = RemoteControl.replyName(for: "bbb")

    expect(a != b, "two concurrent callers must not share an inbox")
    expect(a.rawValue, "dev.nolid.status.aaa", "the name is derived from the token")
    expect(a.rawValue.hasPrefix(RemoteControl.replyPrefix), "and stays under the prefix")
}

// MARK: - Ownership of the mirror cannot be lost by a failed attempt

test("a failed unmirror does not silently forfeit the claim on our own mirror") {
    let (manager, backend, notices, _) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)
    expect(backend.isMirroringAnother(1), "precondition: mirrored by the fallback")

    // First attempt fails. Reported, correctly.
    backend.unmirrorFails = true
    manager.setBuiltInOff(false)
    expect(notices.warnings.isEmpty, false, "the first failure is reported")
    expect(backend.isMirroringAnother(1), "and it is still mirrored")

    // The transient failure clears. A second attempt must still know the mirror
    // is ours, and undo it. Forgetting that is a permanent silent failure.
    backend.unmirrorFails = false
    let recovered = manager.enableAllDisplays()

    expect(backend.isMirroringAnother(1), false, "the retry must actually undo it")
    expect(recovered, "and report success only once it really is undone")
}

test("panic does not call a still-mirrored panel recovered") {
    let (manager, backend, _, _) = makeManager(externals: [2]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)

    backend.unmirrorFails = true
    let recovered = manager.enableAllDisplays()

    // The panel is mirrored at zero brightness. It is still in the active list,
    // so counting active displays alone would call this a success.
    expect(backend.activeDisplays().isEmpty, false, "it is technically still active")
    expect(recovered, false, "but it is not usable, and panic must say so")
}

test("a mirror reconfigured by the user stops being ours") {
    let (manager, backend, _, defaults) = makeManager(externals: [2, 3]) {
        $0.supportsHardDisable = false
    }
    manager.setBuiltInOff(true)
    let ourMaster = backend.mirrorSource(of: 1)
    expect(ourMaster != nil, "precondition: we built a mirror set")

    // Force quit, then the user rebuilds the mirror against the other monitor.
    manager.stop()
    let theirMaster: CGDirectDisplayID = (ourMaster == 2) ? 3 : 2
    backend.setMirror(1, of: theirMaster)

    let reborn = DisplayManager(backend: backend, notices: RecordingNoticeSink(),
                                defaults: defaults)
    reborn.start()
    reborn.enableAllDisplays()

    expect(backend.isMirroringAnother(1), "their arrangement is not ours to undo")
    reborn.stop()
}

// MARK: - Ambiguous topologies are not remembered

test("two different anonymous monitors do not share a saved preference") {
    let anonymous = FakeDisplayBackend()
    anonymous.online = [1, 2]
    anonymous.uuidsUnavailable = true

    let key = DisplayProfiles.key(for: [2], using: anonymous)
    expect(DisplayProfiles.isPersistable(key), false,
           "a key that cannot tell two monitors apart must not be stored")
}

test("an unidentifiable topology falls back rather than guessing") {
    let suite = "dev.nolid.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let profiles = DisplayProfiles(defaults: defaults)
    let anonymous = FakeDisplayBackend()
    anonymous.online = [1, 2]
    anonymous.uuidsUnavailable = true
    let key = DisplayProfiles.key(for: [2], using: anonymous)

    profiles.remember(true, for: key)

    expect(profiles.desiredOff(for: key) == nil,
           "no answer is safer than another monitor's answer")
    expect(profiles.count, 0, "and nothing was written")
}

test("a topology with real UUIDs is still remembered") {
    let suite = "dev.nolid.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)

    let profiles = DisplayProfiles(defaults: defaults)
    let backend = FakeDisplayBackend()
    backend.online = [1, 2]
    let key = DisplayProfiles.key(for: [2], using: backend)

    profiles.remember(true, for: key)

    expect(DisplayProfiles.isPersistable(key), "an identified monitor is storable")
    expect(profiles.desiredOff(for: key), true, "and comes back")
}

// MARK: - Report

if failures.isEmpty {
    print("\(passed) expectations passed")
    exit(0)
}

print("\(passed) passed, \(failures.count) FAILED\n")
for failure in failures { print("  ✗ \(failure)") }
exit(1)
