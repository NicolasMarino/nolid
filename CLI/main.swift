//
//  main.swift
//  NoLid — command line client.
//
//  Standalone binary. For normal operations it never touches displays: it asks
//  the menu bar app to do it, over `DistributedNotificationCenter`, so a single
//  process owns the state and the safety nets live in one place.
//
//  RECOVERY operations are the exception. When the app does not answer —
//  crashed, force quit, never opened — `panic` and `on` act directly on
//  CoreGraphics. That is exactly when they are needed most: a black screen and
//  nobody to ask for help. And being a CLI, it works over SSH from another
//  machine, with nothing to look at.
//
//  Operations that TURN DISPLAYS OFF never run without the app: they depend on
//  the watchdog and the reconfiguration callback to be able to undo themselves.
//

import CoreGraphics
import Foundation

// Must match Sources/RemoteControl.swift
let commandPrefix = "dev.nolid.command."
let replyName = Notification.Name("dev.nolid.status")

/// The app's preferences, to read the saved brightness and the cached built-in
/// display id. The CLI has a different bundle id, so the domain is opened by name.
let appDefaults = UserDefaults(suiteName: "dev.nolid.app")

let usage = """
nolid — control NoLid from the terminal.

USAGE
    nolid <command> [options]

COMMANDS
    on         Turn the built-in display on
    off        Turn the built-in display off (needs an external monitor)
    toggle     Toggle the state
    panic      Restore every display
    status     Show the current state
    doctor     Diagnose which disable method this Mac supports

OPTIONS
    --json     Print the result as JSON (with `status` and `doctor`)
    --no-probe With `doctor`: skip the live test
    -h, --help Show this help

WITHOUT THE APP RUNNING
    `panic`, `on` and `doctor` work anyway: they act directly on
    CoreGraphics. `off` and `toggle` do not, because turning displays off
    without the app's safety nets has no way to undo itself.

EXIT CODES
    0  success
    1  NoLid is not answering and the command needs the app
    2  bad usage
    3  the command had no effect (e.g. turning off with no external monitors)
"""

let center = DistributedNotificationCenter.default()

// MARK: - Channel to the app

func post(_ command: String) {
    center.postNotificationName(
        Notification.Name(commandPrefix + command),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

/// Asks the app for its state and waits for the reply.
/// - Returns: `nil` if the app did not answer within `timeout`.
func requestStatus(timeout: TimeInterval = 1.5) -> [String: Any]? {
    // The observer writes here and the run loop below reads it. Same thread
    // throughout, so no synchronization is needed.
    var reply: String?

    let observer = center.addObserver(forName: replyName, object: nil, queue: .main) { note in
        reply = note.object as? String
    }
    defer { center.removeObserver(observer) }

    post("status")

    let deadline = Date().addingTimeInterval(timeout)
    while reply == nil, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    guard let reply, let data = reply.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Direct recovery, without the app

/// The built-in display according to the system or, once it has left the
/// lists, according to the last id the app wrote down.
func resolveBuiltIn() -> CGDirectDisplayID? {
    if let live = DisplayAPI.builtInDisplay() { return live }
    let stored = appDefaults?.integer(forKey: "lastBuiltInDisplayID") ?? 0
    return stored > 0 ? CGDirectDisplayID(stored) : nil
}

/// Returns every display to a usable state by talking directly to CoreGraphics.
/// Same sequence as the app's panic button.
/// - Returns: `true` when at least one display is active afterwards and the
///   built-in is not left mirroring another one.
@discardableResult
func recoverDirectly() -> Bool {
    var targets = Set(DisplayAPI.onlineDisplays())
    if let builtIn = resolveBuiltIn() { targets.insert(builtIn) }
    for id in targets { DisplayAPI.setEnabled(id, true) }

    if let builtIn = resolveBuiltIn() {
        if DisplayAPI.isMirroringAnother(builtIn) {
            DisplayAPI.setMirror(builtIn, of: nil)
        }
        // Only touch brightness when it is on the floor: if the user turned it
        // down on purpose, that is none of our business.
        if let current = DisplayAPI.brightness(builtIn), current < 0.01 {
            let saved = appDefaults?.object(forKey: "savedBuiltInBrightness") as? Double ?? 0.6
            DisplayAPI.setBrightness(builtIn, Float(saved))
        }
    }

    guard !DisplayAPI.activeDisplays().isEmpty else { return false }
    guard let builtIn = resolveBuiltIn() else { return true }
    return !DisplayAPI.isMirroringAnother(builtIn)
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
let skipProbe = arguments.contains("--no-probe")
arguments.removeAll { $0.hasPrefix("--") }

guard let command = arguments.first else {
    fail(usage, code: 2)
}

if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}

guard ["on", "off", "toggle", "panic", "status", "doctor"].contains(command) else {
    fail("nolid: unknown command '\(command)'\n\n\(usage)", code: 2)
}

// MARK: - doctor

if command == "doctor" {
    runDoctor(json: wantsJSON, probe: !skipProbe)
    exit(0)
}

// MARK: - Commands that change state

if command != "status" {
    let before = requestStatus()

    if before == nil {
        // The app is gone. Only continue when the command recovers displays.
        guard command == "panic" || command == "on" else {
            fail("nolid: NoLid is not answering and '\(command)' needs the app running.", code: 1)
        }
        note("nolid: NoLid is not answering; recovering directly.")
        guard recoverDirectly() else {
            fail("nolid: could not recover any display.", code: 3)
        }
        exit(0)
    }

    let wasOff = before?["builtInOff"] as? Bool ?? false
    let expected: Bool
    switch command {
    case "on", "panic": expected = false
    case "off":         expected = true
    default:            expected = !wasOff // toggle
    }

    post(command)

    // The app applies the change asynchronously, so it has to be polled.
    var applied = false
    let deadline = Date().addingTimeInterval(2.0)
    repeat {
        guard let status = requestStatus() else { break }
        if status["builtInOff"] as? Bool == expected { applied = true; break }
    } while Date() < deadline

    if !applied {
        let canTurnOff = before?["canTurnOff"] as? Bool ?? false
        let reason = canTurnOff ? "the command had no effect" : "no active external monitors"
        fail("nolid: \(reason).", code: 3)
    }
    exit(0)
}

// MARK: - status

guard let status = requestStatus() else {
    fail("nolid: NoLid is not answering. Is the app running?", code: 1)
}

if wantsJSON {
    let data = try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

func text(_ key: String) -> String { status[key] as? String ?? "?" }
func flag(_ key: String) -> String { (status[key] as? Bool ?? false) ? "yes" : "no" }

let externalCount = status["externalCount"] as? Int ?? 0
let externalNames = status["externalNames"] as? [String] ?? []
let externals = externalNames.isEmpty
    ? "\(externalCount)"
    : "\(externalCount) (\(externalNames.joined(separator: ", ")))"

let rows = [
    ("Built-in", (status["builtInOff"] as? Bool ?? false) ? "off" : "active"),
    ("External", externals),
    ("Method", text("methodDescription")),
    ("Automatic mode", flag("autoMode")),
    ("Profiles", flag("profilesEnabled")),
    ("Topology", text("topology")),
]

let width = rows.map(\.0.count).max() ?? 0
for (label, value) in rows {
    let padding = String(repeating: " ", count: width - label.count)
    print("\(label):\(padding)  \(value)")
}
