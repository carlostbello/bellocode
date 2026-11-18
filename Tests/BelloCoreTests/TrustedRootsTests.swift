import BelloCore
import Foundation
import Testing

/// The trusted-roots value handed to the policy layer: inside a root is in scope, a link out of it is not.
@Suite("Trusted roots")
struct TrustedRootsTests {
    @Test func insideRootsAndLinksOut() throws {
        let base = NSTemporaryDirectory() + "bc-trusted-\(UUID().uuidString.prefix(8))"
        let root = base + "/Repos"
        try FileManager.default.createDirectory(atPath: root + "/a/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/a/out", withDestinationPath: base + "/outside")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let trusted = TrustedRoots(paths: [root], source: .configured)
        #expect(trusted.contains(root))
        #expect(trusted.contains(root + "/a/src/main.swift"), "a file that does not exist yet inside a root")
        #expect(trusted.contains(root + "/b/new"), "another repository under the root")
        #expect(!trusted.contains(base + "/outside/x"))
        #expect(!trusted.contains(root + "/a/out/secret"), "a link inside the root that leads outside is outside")
        #expect(!trusted.contains(root + "/../outside"))
        #expect(!trusted.contains(base + "/RepositoriesElsewhere"), "prefix of a name is not containment")
        #expect(!trusted.contains("relative/path"))
        #expect(trusted.scope(projectRoots: [root + "/a"] + trusted.paths) == [root + "/a"] + trusted.paths, "project roots first, no duplicates")
        #expect(trusted.paths.allSatisfy { $0.hasPrefix("/private/") }, "stored with links resolved")
        #expect(TrustedRoots(paths: [], source: .configured).source == .none)
        #expect(!TrustedRoots.none.contains(root))
    }
}
