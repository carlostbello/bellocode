import Foundation
import Testing

/// Which plugin copy the real-binary suites load (`OrchestrationRealBinaryTests.pluginDirectory(root:)`): the bundle's
/// only when it matches `Plugin/`, so a stale `build/BelloCode.app` never runs old plugin code against new tests.
@Suite("Real-binary plugin selection")
struct RealBinaryPluginSelectionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-plugin-pick-\(UUID().uuidString)", directoryHint: .isDirectory)
    var source: URL { root.appending(path: "Plugin", directoryHint: .isDirectory) }
    var bundled: URL { root.appending(path: "build/BelloCode.app/Contents/Resources/opencode-plugin", directoryHint: .isDirectory) }

    func write(_ files: [String: String], to folder: URL) throws {
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    let current = ["server.ts": "new server", "src/pins.ts": "pins", "src/project.ts": "project"]

    @Test func noBundleUsesTheSource() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(current.merging(["package.json": "{}"]) { a, _ in a }, to: source)
        #expect(OrchestrationRealBinaryTests.pluginDirectory(root: root) == source)
    }

    @Test func aMatchingBundleIsUsed() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(current.merging(["package.json": "{}", "test/a.test.ts": "t"]) { a, _ in a }, to: source)
        try write(current, to: bundled)
        #expect(OrchestrationRealBinaryTests.pluginDirectory(root: root) == bundled)
    }

    @Test func aStaleBundleIsIgnored() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(current, to: source)
        // Assembled before a source file was added (the pre-AF08 bundle had no src/pins.ts).
        try write(["server.ts": "new server", "src/project.ts": "project"], to: bundled)
        #expect(OrchestrationRealBinaryTests.pluginDirectory(root: root) == source)
        // Same files, older content.
        try write(["server.ts": "old server", "src/pins.ts": "pins"], to: bundled)
        #expect(OrchestrationRealBinaryTests.pluginDirectory(root: root) == source)
        // A bundle carrying a file the source no longer has.
        try write(["server.ts": "new server", "src/removed.ts": "gone"], to: bundled)
        #expect(OrchestrationRealBinaryTests.pluginDirectory(root: root) == source)
    }
}
