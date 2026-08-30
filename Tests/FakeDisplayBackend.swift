//
//  FakeDisplayBackend.swift
//  NoLid tests
//
//  A display system that can be put into the states that matter and cannot be
//  reproduced on demand with real hardware: a monitor yanked mid-mirror, a
//  private symbol that reports success and does nothing, a mirror call the
//  system refuses.
//

import CoreGraphics
import Foundation

final class FakeDisplayBackend: DisplayBackend {

    /// Connected displays, whether or not they are currently enabled.
    var online: [CGDirectDisplayID] = []
    var builtIn: CGDirectDisplayID? = 1

    /// Hard-disabled displays: still online, no longer active.
    var hardDisabled: Set<CGDirectDisplayID> = []
    /// Mirrored display -> its master.
    var mirrors: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    var brightnessValues: [CGDirectDisplayID: Float] = [:]

    var supportsHardDisable = true
    var supportsBrightness = true

    /// The failure mode that motivated the whole two-method design: the call
    /// returns success and the display stays exactly where it was.
    var hardDisableLies = false
    /// The system refuses the call outright.
    var hardDisableRejects = false
    /// Mirroring is unavailable too, leaving no way to turn the panel off.
    var mirrorFails = false
    /// The way back fails: the display stays hard-disabled however many times
    /// it is asked to come back. This is the catastrophic case — the user is
    /// left with no screen — and the one the suite could not represent before.
    var reEnableFails = false
    /// Only these ids refuse to come back. Models the id that went stale while
    /// the display was disabled: the call is accepted for everything else, so
    /// a sweep succeeds exactly where a single targeted retry cannot.
    var reEnableFailsFor: Set<CGDirectDisplayID> = []
    /// Undoing a mirror fails, so the panel stays mirrored at zero brightness.
    var unmirrorFails = false

    private(set) var setEnabledCalls: [(CGDirectDisplayID, Bool)] = []

    /// Fires after each `setEnabled`, so a test can change the hardware halfway
    /// through an operation. Real monitors get unplugged mid-transaction, and
    /// the branches that handle it are unreachable any other way.
    var afterSetEnabled: ((CGDirectDisplayID, Bool) -> Void)?

    // MARK: Setup helpers

    func connect(_ ids: CGDirectDisplayID...) { online.append(contentsOf: ids) }

    func unplugExternals() {
        online.removeAll { $0 != builtIn }
        // macOS tears down a mirror set whose master went away.
        mirrors = mirrors.filter { online.contains($0.value) }
    }

    // MARK: DisplayBackend

    func onlineDisplays() -> [CGDirectDisplayID] { online }

    func activeDisplays() -> [CGDirectDisplayID] {
        online.filter { !hardDisabled.contains($0) }
    }

    func isBuiltIn(_ id: CGDirectDisplayID) -> Bool { id == builtIn }

    func builtInDisplay() -> CGDirectDisplayID? {
        guard let builtIn, online.contains(builtIn) else { return nil }
        return builtIn
    }

    func isMirroringAnother(_ id: CGDirectDisplayID) -> Bool { mirrors[id] != nil }
    func mirrorSource(of id: CGDirectDisplayID) -> CGDirectDisplayID? { mirrors[id] }

    /// No display reports a stable identity — docks, KVMs and virtual displays.
    var uuidsUnavailable = false

    func uuid(_ id: CGDirectDisplayID) -> String? {
        uuidsUnavailable ? nil : "uuid-\(id)"
    }
    func name(_ id: CGDirectDisplayID) -> String { id == builtIn ? "Built-in" : "Monitor \(id)" }

    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        setEnabledCalls.append((id, enabled))
        defer { afterSetEnabled?(id, enabled) }

        if enabled {
            guard !reEnableFails, !reEnableFailsFor.contains(id) else { return false }
            hardDisabled.remove(id)
            if !online.contains(id) { online.append(id) }
            return true
        }

        guard supportsHardDisable, !hardDisableRejects else { return false }
        if hardDisableLies { return true }   // success, nothing happens
        hardDisabled.insert(id)
        return true
    }

    @discardableResult
    func setMirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
        if master == nil {
            guard !unmirrorFails else { return false }
            mirrors.removeValue(forKey: id)
            return true
        }
        guard !mirrorFails else { return false }
        mirrors[id] = master
        return true
    }

    @discardableResult
    func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard supportsBrightness else { return false }
        brightnessValues[id] = value
        return true
    }

    func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard supportsBrightness else { return nil }
        return brightnessValues[id] ?? 0.6
    }
}

/// Records notices instead of putting anything on screen.
final class RecordingNoticeSink: NoticeSink {
    private(set) var warnings: [String] = []
    private(set) var infos: [String] = []

    func warn(_ message: String) { warnings.append(message) }
    func inform(_ message: String) { infos.append(message) }
    func resetThrottle() {}
}
