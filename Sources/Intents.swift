//
//  Intents.swift
//  NoLid — Shortcuts / App Intents support.
//
//  Exposes the same four actions the menu and the CLI expose, so NoLid can be
//  driven from Shortcuts, Focus mode automations, Raycast and anything else
//  that speaks App Intents.
//
//  The intents run inside the app's own process, so they go through
//  DisplayManager and inherit every safety net. If the app is not running the
//  system launches it first; it is an agent, so nothing appears on screen.
//

import AppIntents
import AppKit

/// Result text shared by every intent, so Shortcuts always reports the state
/// it actually left the machine in rather than the state that was requested.
@available(macOS 13.0, *)
private func currentSummary() -> String {
    let manager = DisplayManager.shared
    let state = manager.isBuiltInOff ? "off" : "active"
    let count = manager.externalDisplays.count
    return "Built-in display \(state), \(count) external monitor\(count == 1 ? "" : "s")."
}

@available(macOS 13.0, *)
struct ToggleBuiltInDisplayIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Built-in Display"
    static var description = IntentDescription(
        "Turns the MacBook built-in display off, or back on if it is already off."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DisplayManager.shared.toggleBuiltIn()
        return .result(dialog: IntentDialog(stringLiteral: currentSummary()))
    }
}

@available(macOS 13.0, *)
struct TurnOffBuiltInDisplayIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off Built-in Display"
    static var description = IntentDescription(
        "Turns the MacBook built-in display off. Needs at least one external monitor."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = DisplayManager.shared
        // A real Shortcuts error, not a silent no-op: an automation that cannot
        // do what it was asked should say so.
        guard manager.canTurnOffBuiltIn else { throw NoLidIntentError.noExternalMonitors }
        manager.setBuiltInOff(true)
        return .result(dialog: IntentDialog(stringLiteral: currentSummary()))
    }
}

@available(macOS 13.0, *)
struct TurnOnBuiltInDisplayIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn On Built-in Display"
    static var description = IntentDescription("Turns the MacBook built-in display back on.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DisplayManager.shared.setBuiltInOff(false)
        return .result(dialog: IntentDialog(stringLiteral: currentSummary()))
    }
}

@available(macOS 13.0, *)
struct RestoreAllDisplaysIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore All Displays"
    static var description = IntentDescription(
        "Panic button: brings every display back to a usable state."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        DisplayManager.shared.enableAllDisplays()
        return .result(dialog: IntentDialog(stringLiteral: currentSummary()))
    }
}

@available(macOS 13.0, *)
enum NoLidIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noExternalMonitors

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noExternalMonitors:
            return "No active external monitors, so the built-in display cannot be turned off."
        }
    }
}

/// Ready-made phrases so the actions work without the user building a shortcut.
@available(macOS 13.0, *)
struct NoLidShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleBuiltInDisplayIntent(),
            phrases: ["Toggle the built-in display with \(.applicationName)"],
            shortTitle: "Toggle Built-in",
            systemImageName: "laptopcomputer"
        )
        AppShortcut(
            intent: TurnOffBuiltInDisplayIntent(),
            phrases: ["Turn off the built-in display with \(.applicationName)"],
            shortTitle: "Turn Off Built-in",
            systemImageName: "display.2"
        )
        AppShortcut(
            intent: TurnOnBuiltInDisplayIntent(),
            phrases: ["Turn on the built-in display with \(.applicationName)"],
            shortTitle: "Turn On Built-in",
            systemImageName: "laptopcomputer"
        )
        AppShortcut(
            intent: RestoreAllDisplaysIntent(),
            phrases: ["Restore all displays with \(.applicationName)"],
            shortTitle: "Restore All Displays",
            systemImageName: "arrow.clockwise"
        )
    }
}
