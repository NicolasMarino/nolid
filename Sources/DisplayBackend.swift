//
//  DisplayBackend.swift
//  NoLid
//
//  The seam that makes the state machine testable.
//
//  DisplayManager owns the rules that keep a usable display on screen, and
//  those rules are the part that must never regress. Calling DisplayAPI's
//  static methods directly made them impossible to exercise without real
//  hardware in a real failure state — unplugging monitors by hand is not a
//  test suite.
//
//  Everything DisplayManager needs from the outside world goes through this
//  protocol instead (and through NoticeSink, which lives beside Notifier). Production wires them to the real implementations;
//  tests wire them to fakes that can simulate a lying symbol, a vanished
//  monitor, or a mirror macOS tore down on its own.
//

import CoreGraphics
import Foundation

// MARK: - Displays

protocol DisplayBackend {
    var supportsHardDisable: Bool { get }
    var supportsBrightness: Bool { get }

    func onlineDisplays() -> [CGDirectDisplayID]
    func activeDisplays() -> [CGDirectDisplayID]
    func isBuiltIn(_ id: CGDirectDisplayID) -> Bool
    func builtInDisplay() -> CGDirectDisplayID?
    func isMirroringAnother(_ id: CGDirectDisplayID) -> Bool

    func uuid(_ id: CGDirectDisplayID) -> String?
    func name(_ id: CGDirectDisplayID) -> String

    @discardableResult func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool
    @discardableResult func setMirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool
    @discardableResult func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool
    func brightness(_ id: CGDirectDisplayID) -> Float?
}

/// The real thing. A thin forwarder, deliberately holding no logic of its own:
/// anything it decided would be a decision the tests could not reach.
struct SystemDisplayBackend: DisplayBackend {
    var supportsHardDisable: Bool { DisplayAPI.supportsHardDisable }
    var supportsBrightness: Bool { DisplayAPI.supportsBrightness }

    func onlineDisplays() -> [CGDirectDisplayID] { DisplayAPI.onlineDisplays() }
    func activeDisplays() -> [CGDirectDisplayID] { DisplayAPI.activeDisplays() }
    func isBuiltIn(_ id: CGDirectDisplayID) -> Bool { DisplayAPI.isBuiltIn(id) }
    func builtInDisplay() -> CGDirectDisplayID? { DisplayAPI.builtInDisplay() }
    func isMirroringAnother(_ id: CGDirectDisplayID) -> Bool { DisplayAPI.isMirroringAnother(id) }

    func uuid(_ id: CGDirectDisplayID) -> String? { DisplayAPI.uuid(id) }
    func name(_ id: CGDirectDisplayID) -> String { DisplayAPI.name(id) }

    @discardableResult
    func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
        DisplayAPI.setEnabled(id, enabled)
    }

    @discardableResult
    func setMirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
        DisplayAPI.setMirror(id, of: master)
    }

    @discardableResult
    func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        DisplayAPI.setBrightness(id, value)
    }

    func brightness(_ id: CGDirectDisplayID) -> Float? { DisplayAPI.brightness(id) }
}
