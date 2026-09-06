//
//  Log.swift
//  NoLid
//
//  A record of what the safety machinery did, kept where it survives the
//  failure it describes.
//
//  It exists because a black screen leaves no evidence. There is nobody to read
//  a notification, nothing to screenshot, and the one report that comes back is
//  "it stayed black" — which is a symptom shared by every possible cause. The
//  unified log is readable afterwards, from another machine or after a reboot:
//
//      log show --last 1h --predicate 'subsystem == "dev.nolid.app"' --info
//
//  Deliberately narrow. Only the moments where a display was supposed to come
//  back are recorded, because a log nobody can search is the same as no log.
//

import CoreGraphics
import Foundation
import os

enum Log {

    private static let recovery = Logger(subsystem: "dev.nolid.app", category: "recovery")

    /// The screen went empty. The single most important line in this file.
    static func emptyScreen(attempt: Int, of total: Int) {
        recovery.error("no active displays — rescue attempt \(attempt, privacy: .public) of \(total, privacy: .public)")
    }

    /// A display came back, and which path found it.
    static func recovered(_ how: String, active: Int) {
        recovery.notice("recovered via \(how, privacy: .public) — \(active, privacy: .public) active display(s)")
    }

    /// The way back failed. Includes the numbers needed to tell the causes
    /// apart afterwards: a refused call and a stale id look identical from the
    /// outside, and only these three counts separate them.
    static func recoveryFailed(builtIn: CGDirectDisplayID?, online: Int, active: Int) {
        recovery.error("""
            could not restore any display — \
            builtIn=\(builtIn.map(String.init) ?? "none", privacy: .public) \
            online=\(online, privacy: .public) active=\(active, privacy: .public)
            """)
    }

    /// State changes worth correlating against a later failure.
    ///
    /// `.notice`, not `.info`. The unified log keeps info-level entries in
    /// memory and never writes them to disk, so they do not survive the reboot
    /// that a black screen usually ends in — which is the only moment anyone
    /// would want to read them.
    static func state(_ message: String) {
        recovery.notice("\(message, privacy: .public)")
    }
}
