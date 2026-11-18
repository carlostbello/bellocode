import Foundation
import Testing

/// Fails when code under `Sources/` or `Tests/` starts a `Process` without choosing its standard input. A child that
/// inherits it reads whatever the parent was given: a terminal, or the open pipe or socket an agent or CI runs the
/// tests with, which never reaches end of file. A repository's fsmonitor hook or filter that reads input (`cat`) then
/// blocks git forever; this hung HostGitIsolationTests past its time limit and the whole test run with it.
///
/// Set `standardInput` (to `FileHandle.nullDevice` unless the child needs input) within the lines after `Process()`.
@Suite("Child stdin guard")
struct ChildStdinGuardTests {
    /// Lines after `let x = Process()` in which `x.standardInput` must be set.
    static let window = 20

    @Test func everyProcessChoosesItsStandardInput() throws {
        let root = TimerGuardTests.packageRoot
        var offenders: [String] = []
        for folder in ["Sources", "Tests"] {
            let base = root.appending(path: folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    guard let name = Self.processVariable(line) else { continue }
                    let following = lines[(index + 1)..<min(lines.count, index + 1 + Self.window)]
                    if !following.contains(where: { $0.contains("\(name).standardInput") }) {
                        offenders.append("\(url.path.replacingOccurrences(of: root.path + "/", with: "")):\(index + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Process without standardInput: \(offenders)")
    }

    /// `x` in `let x = Process()` / `var x = Process()`.
    static func processVariable(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), trimmed.hasSuffix("= Process()") else { return nil }
        let words = trimmed.split(separator: " ")
        guard words.count >= 4, words[0] == "let" || words[0] == "var" else { return nil }
        return String(words[1])
    }
}
