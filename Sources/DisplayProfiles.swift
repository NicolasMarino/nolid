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

        let ids = externals.map { backend.uuid($0) ?? "id-\($0)" }.sorted()
        return ids.joined(separator: "+")
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

    /// Stored preference for this topology, or `nil` if it was never saved.
    func desiredOff(for key: String) -> Bool? {
        store[key]
    }

    func remember(_ desiredOff: Bool, for key: String) {
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
