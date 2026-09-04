//
//  UpdateCheck.swift
//  NoLid
//
//  Tells you a newer release exists. Does not install it.
//
//  Installing is deliberately left alone. The app and the `nolid` CLI share a
//  control channel whose shape changes between versions, so replacing the app
//  behind the user's back would manufacture the exact mismatch that reports
//  "NoLid is not answering" while the app is plainly running — for everyone, at
//  once, silently. An updater that can only reach half the pair has no business
//  running unattended.
//
//  It also would not buy much: the app is ad-hoc signed, so a downloaded update
//  still meets Gatekeeper on first launch. The click it saves is not the click
//  that hurts.
//

import Foundation

enum UpdateCheck {

    /// Where the answer comes from. A plain public endpoint: the request
    /// carries no identifier, no version, no telemetry — only the fact that
    /// some machine asked GitHub what the latest release is.
    static let endpoint = URL(
        string: "https://api.github.com/repos/NicolasMarino/nolid/releases/latest")!

    static let releasesPage = URL(
        string: "https://github.com/NicolasMarino/nolid/releases/latest")!

    // MARK: - Comparison

    /// Numeric components of a version string, or `nil` when it is not one.
    ///
    /// A leading `v` is accepted because that is how the tags are spelled. A
    /// pre-release suffix is rejected outright rather than parsed: `/releases/
    /// latest` already excludes them, and offering someone a release candidate
    /// they did not ask for is worse than offering nothing.
    ///
    /// - Note: that rejection is deliberately redundant. `Int("0-rc")` fails on
    ///   its own, so removing the check below changes no answer this suite can
    ///   observe — it is kept because it states the decision where the decision
    ///   is made, instead of leaving it as a side effect of how a component
    ///   happens to be parsed. The behaviour is pinned by the tests either way.
    static func components(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty, !text.contains("-"), !text.contains("+") else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// `true` when `candidate` is a strictly later version than `current`.
    ///
    /// Compared component by component, never as text: "0.10.0" sorts before
    /// "0.9.0" as a string, and a released 0.10.0 that nobody was told about is
    /// the whole failure this is meant to avoid. Missing trailing components
    /// count as zero, so "0.2" and "0.2.0" are the same version.
    ///
    /// Anything unparseable answers `false`. A version this build cannot read
    /// is not grounds to tell someone they are out of date.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else {
            return false
        }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Fetching

    /// Asks GitHub for the latest published tag.
    ///
    /// Every failure is silent. A checker that complains about its own network
    /// trouble has turned a convenience into a nuisance, and there is nothing
    /// the user could do about it anyway.
    static func fetchLatestTag(session: URLSession = .shared,
                               completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return completion(nil) }
            completion(tag)
        }.resume()
    }
}
