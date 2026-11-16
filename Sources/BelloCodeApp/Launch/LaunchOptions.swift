import Foundation

/// The command-line modes the app understands. Parsed once at launch; pure, so it is tested directly.
///
/// - (none): the normal app. Uses the bundled opencode, or `BELLOCODE_SERVER_URL` when set.
/// - `--mock [demo|large]`: an in-process MockOpenCode server with a temporary cache (UI work without a model).
/// - `--snapshot <name>`: build the window against a mock scenario, render PNGs to `build/snapshots/`, exit.
/// - `--smoke-test`: headless check of the bundled opencode through the supervisor and engine, then exit.
struct LaunchOptions: Equatable, Sendable {
    enum MockScenario: String, Equatable, Sendable, CaseIterable {
        case demo, large
    }

    enum Mode: Equatable, Sendable {
        case app
        case smokeTest
        case snapshot(name: String)
    }

    var mode: Mode = .app
    /// Set by `--mock` (and implied by `--snapshot`).
    var mock: MockScenario?
    /// Where `--snapshot` writes (default `build/snapshots` under the current directory).
    var snapshotDirectory: String?

    struct ParseError: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    static func parse(_ arguments: [String]) throws(ParseError) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func value(after flag: String) -> String? {
            let next = index + 1
            guard next < arguments.count, !arguments[next].hasPrefix("-") else { return nil }
            index = next
            return arguments[next]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--smoke-test":
                options.mode = .smokeTest
            case "--mock":
                if let name = value(after: argument) {
                    guard let scenario = MockScenario(rawValue: name) else {
                        throw ParseError(description: "unknown mock scenario '\(name)' (use demo or large)")
                    }
                    options.mock = scenario
                } else {
                    options.mock = .demo
                }
            case "--snapshot":
                guard let name = value(after: argument) else { throw ParseError(description: "--snapshot needs a name") }
                guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                    throw ParseError(description: "snapshot names use letters, digits, - and _")
                }
                options.mode = .snapshot(name: name)
            case "--snapshot-dir":
                guard let directory = value(after: argument) else { throw ParseError(description: "--snapshot-dir needs a path") }
                options.snapshotDirectory = directory
            default:
                // AppKit and the debugger pass their own (-NSDocumentRevisionsDebugMode YES, -ApplePersistenceIgnoreState …).
                if argument.hasPrefix("-"), !argument.hasPrefix("--"), index + 1 < arguments.count,
                    !arguments[index + 1].hasPrefix("-")
                {
                    index += 1
                }
            }
            index += 1
        }
        if case .snapshot = options.mode, options.mock == nil { options.mock = .demo }
        return options
    }
}
