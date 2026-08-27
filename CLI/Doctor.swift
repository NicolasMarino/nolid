//
//  Doctor.swift
//  NoLid — diagnostics output.
//
//  The decision lives in Sources/CapabilityProbe.swift so it can be tested
//  against a fake backend. What is left here is presentation.
//

import CoreGraphics
import Foundation

func runDoctor(json: Bool, probe: Bool) {
    let backend = SystemDisplayBackend()
    let builtIn = resolveBuiltIn()
    let externals = DisplayAPI.activeDisplays().filter { !DisplayAPI.isBuiltIn($0) }
    let appStatus = requestStatus(timeout: 0.6)

    let result = CapabilityProbe(backend: backend).run(
        builtIn: builtIn,
        enabled: probe,
        appReportsOff: appStatus?["builtInOff"] as? Bool == true
    )

    if json {
        emitJSON(builtIn: builtIn, externals: externals, appStatus: appStatus, result: result)
    } else {
        emitText(builtIn: builtIn, externals: externals, appStatus: appStatus, result: result)
    }
}

// MARK: - Output

private func describe(_ id: CGDirectDisplayID, kind: String) -> (String, String, String) {
    (kind, DisplayAPI.name(id), DisplayAPI.uuid(id) ?? "no UUID")
}

private func emitText(builtIn: CGDirectDisplayID?, externals: [CGDirectDisplayID],
                      appStatus: [String: Any]?, result: ProbeResult) {
    print("NoLid doctor\n")

    print("System")
    let rows = [
        ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
        ("Architecture", machineArchitecture()),
        ("Hard disable", DisplayAPI.supportsHardDisable
            ? "symbol resolved (SLSConfigureDisplayEnabled)" : "unavailable"),
        ("Brightness control", DisplayAPI.supportsBrightness
            ? "available (DisplayServices)" : "unavailable"),
        ("App", appStatus == nil ? "not answering" : "running"),
    ]
    let width = rows.map(\.0.count).max() ?? 0
    for (label, value) in rows {
        print("  \(label.padding(toLength: width, withPad: " ", startingAt: 0))   \(value)")
    }

    print("\nDisplays")
    var entries: [(String, String, String)] = []
    if let builtIn { entries.append(describe(builtIn, kind: "built-in")) }
    entries += externals.map { describe($0, kind: "external") }
    if entries.isEmpty {
        print("  none detected")
    } else {
        let kindWidth = entries.map(\.0.count).max() ?? 0
        let nameWidth = entries.map(\.1.count).max() ?? 0
        for (kind, name, uuid) in entries {
            let k = kind.padding(toLength: kindWidth, withPad: " ", startingAt: 0)
            let n = name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("  \(k)   \(n)   \(uuid)")
        }
    }

    print("\nLive probe")
    print("  \(result.detail.isEmpty ? "no data" : result.detail)")

    print("\nVerdict")
    print("  \(result.verdict)")
}

private func emitJSON(builtIn: CGDirectDisplayID?, externals: [CGDirectDisplayID],
                      appStatus: [String: Any]?, result: ProbeResult) {
    func entry(_ id: CGDirectDisplayID, _ kind: String) -> [String: Any] {
        ["kind": kind, "name": DisplayAPI.name(id), "uuid": DisplayAPI.uuid(id) ?? ""]
    }
    var displays: [[String: Any]] = []
    if let builtIn { displays.append(entry(builtIn, "built-in")) }
    displays += externals.map { entry($0, "external") }

    let payload: [String: Any] = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "architecture": machineArchitecture(),
        "hardDisableSymbol": DisplayAPI.supportsHardDisable,
        "brightnessControl": DisplayAPI.supportsBrightness,
        "appRunning": appStatus != nil,
        "displays": displays,
        "probe": ["outcome": result.outcome.rawValue, "detail": result.detail],
        "verdict": result.verdict,
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else { return }
    print(String(decoding: data, as: UTF8.self))
}

private func machineArchitecture() -> String {
    var info = utsname()
    guard uname(&info) == 0 else { return "unknown" }
    return withUnsafeBytes(of: &info.machine) { raw in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}
