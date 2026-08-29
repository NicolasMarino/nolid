//
//  DisplayProfiles.swift
//  NoLid
//
//  Remembers what you wanted for each set of monitors.
//
//  Two externals at home with the built-in off; one at the office with the
//  built-in on as a secondary display. Without profiles there is a single
//  global preference and automatic mode decides everything from topology.
//

import CoreGraphics
import Foundation

struct DisplayProfiles {

    private enum Key {
        static let enabled = "profilesEnabled"
        static let store = "displayProfiles"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// With profiles enabled, topology wins over the global preference.
    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    // MARK: - Topology identity

    /// Stable key for the set of connected external monitors.
    ///
    /// UUIDs are used instead of `CGDirectDisplayID` because the id is
    /// reassigned on every reconnect. They are sorted so plug order cannot
    /// produce two different profiles for the same pair of monitors.
    static func key(for externals: [CGDirectDisplayID], using backend: DisplayBackend) -> String {
        guard !externals.isEmpty else { return "builtin-only" }

        // A display with no stable identity gets a constant marker, never its
        // `CGDirectDisplayID`: that is reassigned on reconnect, so a key built
        // from it would be different every time and the profile saved under it
        // could never be found again.
        //
        // The marker makes the key stable, but not unique — two different
        // anonymous monitors produce the same one. `isPersistable` refuses those
        // keys rather than hand someone another monitor's preference.
        let ids = externals.map { backend.uuid($0) ?? Self.unidentified }.sorted()
        return ids.joined(separator: "+")
    }

    /// Marker for a display that reports no stable identity of any kind.
    static let unidentified = "unidentified"

    /// `false` when the key cannot tell this set of monitors apart from another.
    ///
    /// Remembering an ambiguous topology is worse than remembering nothing:
    /// no profile falls back to automatic mode, which is at least about the
    /// monitors actually connected. A wrong profile confidently applies a
    /// decision made for hardware that is not plugged in.
    static func isPersistable(_ key: String) -> Bool {
        !key.split(separator: "+").contains(Substring(unidentified))
    }

    /// Human-readable profile name, for the menu.
    static func label(for externals: [CGDirectDisplayID], using backend: DisplayBackend) -> String {
        guard !externals.isEmpty else { return "Built-in display only" }

        let names = externals.map { backend.name($0) }.sorted()
        return names.joined(separator: " + ")
    }

    // MARK: - Store

    private var store: [String: Bool] {
        defaults.dictionary(forKey: Key.store) as? [String: Bool] ?? [:]
    }

    /// Stored preference for this topology, or `nil` if it was never saved —
    /// or if this topology cannot be told apart from another one.
    func desiredOff(for key: String) -> Bool? {
        guard Self.isPersistable(key) else { return nil }
        return store[key]
    }

    func remember(_ desiredOff: Bool, for key: String) {
        guard Self.isPersistable(key) else { return }
        var current = store
        current[key] = desiredOff
        defaults.set(current, forKey: Key.store)
    }

    func forget(_ key: String) {
        var current = store
        current.removeValue(forKey: key)
        defaults.set(current, forKey: Key.store)
    }

    func forgetAll() {
        defaults.removeObject(forKey: Key.store)
    }

    var count: Int { store.count }
}
