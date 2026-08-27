//
//  CommandLineOptions.swift
//  NoLid
//
//  Argument parsing for the `nolid` CLI, kept here rather than inline in the
//  tool so it can be tested. It is fifteen lines of logic that shipped a bug:
//  stripping `--` options before looking for the verb ate `--help`, so asking
//  for help printed usage to stderr and exited 2.
//

import Foundation

struct CommandLineOptions: Equatable {

    /// The verb, or `nil` when none was given.
    var command: String?
    var wantsHelp = false
    var wantsJSON = false
    var skipProbe = false

    /// Everything that looked like an option but is not one we know.
    var unknownOptions: [String] = []

    private static let known = ["--json", "--no-probe", "--help"]

    /// - Parameter arguments: `CommandLine.arguments` without the program name.
    init(arguments: [String]) {
        // Help is checked first and against the raw list. Filtering options out
        // before looking for it is what broke it the first time.
        wantsHelp = arguments.contains { $0 == "-h" || $0 == "--help" || $0 == "help" }
        wantsJSON = arguments.contains("--json")
        skipProbe = arguments.contains("--no-probe")

        unknownOptions = arguments.filter { $0.hasPrefix("-") && !Self.known.contains($0) && $0 != "-h" }
        command = arguments.first { !$0.hasPrefix("-") && $0 != "help" }
    }
}
