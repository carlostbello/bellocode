import Foundation

/// The command-line modes the app understands. Parsed once at launch; pure, so it is tested directly.
///
/// - (none): the normal app. Uses the bundled, supervised opencode (development builds: `BELLOCODE_SERVER_URL` attaches
///   to another server, in a separate data namespace).
/// - `--mock [demo|large]`: an in-process MockOpenCode server with a temporary cache (UI work without a model).
///   Development builds only.
/// - `--snapshot <name>`: build the window against a mock scenario, render PNGs to `build/snapshots/`, exit.
///   Development builds only.
/// - `--smoke-test`: headless check of the bundled opencode through the supervisor and engine, then exit.
struct LaunchOptions: Equatable, Sendable {
    enum MockScenario: String, Equatable, Sendable, CaseIterable {
        case demo, large
        /// Three projects with 24 threads (navigation snapshots: sections, palette, search).
        case workspace
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

    /// True in development (debug) builds: mock, snapshot and attach modes exist only there (S1 in
    /// docs/reviews/deep-review-1.md). A release build runs only the bundled, supervised server.
    static var allowsDevelopmentModes: Bool {
        #if BELLOCODE_DEVELOPMENT
        true
        #else
        false
        #endif
    }

    static func parse(_ arguments: [String], development: Bool = allowsDevelopmentModes) throws(ParseError) -> LaunchOptions {
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
            if !development, ["--mock", "--snapshot", "--snapshot-dir"].contains(argument) {
                throw ParseError(description: "\(argument) is available only in development builds")
            }
            switch argument {
            case "--smoke-test":
                options.mode = .smokeTest
            case "--mock":
                if let name = value(after: argument) {
                    guard let scenario = MockScenario(rawValue: name) else {
                        throw ParseError(description: "unknown mock scenario '\(name)' (use demo, large or workspace)")
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
        if case .snapshot(let name) = options.mode, options.mock == nil { options.mock = name == "nav" || name == "extras" || name == "gitlab" || name == "containers" || name == "containers3" ? .workspace : .demo }
        return options
    }
}
