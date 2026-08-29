//
//  CapabilityProbe.swift
//  NoLid
//
//  What `nolid doctor` actually decides.
//
//  The symbol resolving through dlsym proves nothing: it can return success and
//  disable nothing. The only honest answer comes from performing the real
//  disable and checking whether the panel left the active display list.
//
//  That logic lives here rather than in the CLI so it can be tested against a
//  fake backend. Lying symbols and rejected calls are exactly the states that
//  cannot be produced on demand with real hardware, and they are the states the
//  verdict exists to tell apart.
//

import CoreGraphics
import Foundation

enum ProbeOutcome: String {
    case hardDisableWorks = "hard-disable-works"
    case reportsSuccessButDoesNothing = "reports-success-does-nothing"
    case callRejected = "call-rejected"
    case symbolUnavailable = "symbol-unavailable"
    case skipped = "skipped"
}

struct ProbeResult {
    var outcome: ProbeOutcome
    var detail: String

    /// `false` only when the probe physically disabled the built-in display and
    /// could not bring it back. It is deliberately separate from `outcome`:
    /// "hard disable works" and "the screen is still dark" are both true at
    /// once, and collapsing them would let the good news hide the bad.
    var restored = true

    var verdict: String {
        switch outcome {
        case .hardDisableWorks:
            return "This Mac supports hard disable. NoLid will turn the backlight off."
        case .reportsSuccessButDoesNothing:
            return "The symbol lies on this Mac: NoLid detects it and uses the mirroring fallback."
        case .callRejected:
            return "The system rejects hard disable. NoLid will use the mirroring fallback."
        case .symbolUnavailable:
            return "No hard disable on this macOS. NoLid will use the mirroring fallback."
        case .skipped:
            return "No live probe, no verdict: the symbol existing does not prove it works."
        }
    }
}

struct CapabilityProbe {

    let backend: DisplayBackend

    /// - Parameters:
    ///   - builtIn: the built-in display, or `nil` if none was found.
    ///   - enabled: `false` when the user passed `--no-probe`.
    ///   - appReportsOff: the running app's own view, so we never probe a panel
    ///     NoLid already turned off and report nonsense.
    func run(builtIn: CGDirectDisplayID?, enabled: Bool, appReportsOff: Bool) -> ProbeResult {
        guard enabled else {
            return ProbeResult(outcome: .skipped, detail: "skipped by --no-probe")
        }
        guard backend.supportsHardDisable else {
            return ProbeResult(outcome: .symbolUnavailable,
                               detail: "the symbol does not exist on this macOS")
        }
        guard let builtIn else {
            return ProbeResult(outcome: .skipped, detail: "no built-in display found")
        }
        guard !externals().isEmpty else {
            return ProbeResult(outcome: .skipped,
                               detail: "an external monitor must be connected")
        }
        guard !backend.isMirroringAnother(builtIn) else {
            return ProbeResult(outcome: .skipped,
                               detail: "the built-in display is already mirroring another one")
        }
        guard !appReportsOff else {
            return ProbeResult(outcome: .skipped,
                               detail: "the built-in display is already off, turned off by NoLid")
        }
        return probe(builtIn)
    }

    func externals() -> [CGDirectDisplayID] {
        backend.activeDisplays().filter { !backend.isBuiltIn($0) }
    }

    // MARK: - The live probe

    /// Turns the built-in off, checks whether it truly vanished, and restores it.
    /// The restore is retried: leaving the user in the dark over a diagnostic
    /// would be exactly the failure this app exists to prevent.
    private func probe(_ builtIn: CGDirectDisplayID) -> ProbeResult {
        let accepted = backend.setEnabled(builtIn, false)
        let disappeared = !backend.activeDisplays().contains(builtIn)

        var restored = restore(builtIn)
        for _ in 0..<4 where !restored {
            usleep(200_000)
            restored = restore(builtIn)
        }

        let suffix = restored ? "" : "  WARNING: the built-in display could not be restored."

        if !accepted {
            return ProbeResult(outcome: .callRejected,
                               detail: "the call was rejected by the system" + suffix,
                               restored: restored)
        }
        if disappeared {
            // Deliberately not "and came back" when it did not: the probe is the
            // one command allowed to turn a display off with no watchdog behind
            // it, so it does not get to describe a failure as a success.
            let ending = restored ? " and came back" : ""
            return ProbeResult(
                outcome: .hardDisableWorks,
                detail: "the built-in display left the active display list" + ending + suffix,
                restored: restored
            )
        }
        return ProbeResult(
            outcome: .reportsSuccessButDoesNothing,
            detail: "the call returned success but the display stayed active" + suffix,
            restored: restored
        )
    }

    private func restore(_ builtIn: CGDirectDisplayID) -> Bool {
        backend.setEnabled(builtIn, true)
        if backend.isMirroringAnother(builtIn) { backend.setMirror(builtIn, of: nil) }
        return backend.activeDisplays().contains(builtIn)
    }
}
