import Foundation
import Testing

@testable import ContainerKit

/// Code roots (docs/features/containers.md, "Code roots"): validation and the first-run suggestion. Every path is a
/// temporary folder standing in for the home folder; nothing touches the real home or Documents.
@Suite("Code roots")
struct CodeRootsTests {
    let home: String
    let base: String

    init() throws {
        // Canonical (`/private/var/…`): a URL would shorten it to the `/var` link.
        base = (CodeRoots.canonical(NSTemporaryDirectory()) ?? NSTemporaryDirectory()) + "/bc-roots-\(UUID().uuidString.prefix(8))"
        home = base + "/home"
        for folder in ["Documents/Repos/a", "Documents/Repos/b", "work/x", "Documents/solo", ".ssh", "Library/Keys", "plain"] {
            try FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/file.txt", contents: Data())
        try FileManager.default.createSymbolicLink(atPath: home + "/repos-link", withDestinationPath: home + "/Documents/Repos")
        try FileManager.default.createSymbolicLink(atPath: home + "/Documents/Repos/evil", withDestinationPath: "/etc")
    }

    /// Everything under the fake home (and the temporary folders) counts as shared with Rancher Desktop.
    var shared: [String] { [home] }

    func kinds(_ path: String) -> Set<CodeRootIssue.Kind> {
        Set(CodeRoots.issues(for: path, home: home, sharedPrefixes: shared).map(\.kind))
    }

    @Test func aRepositoriesFolderIsValid() {
        #expect(kinds(home + "/Documents/Repos").isEmpty, "\(CodeRoots.issues(for: home + "/Documents/Repos", home: home, sharedPrefixes: shared))")
        #expect(kinds("~/Documents/Repos").isEmpty, "~ expands to the home folder")
        #expect(kinds(home + "/Documents/Repos/").isEmpty, "a trailing slash is ignored")
    }

    @Test func homeRootSystemAndSensitiveLocationsAreRefused() {
        #expect(kinds(home).contains(.wholeHome))
        #expect(kinds("~").contains(.wholeHome))
        #expect(kinds(base).contains(.wholeHome), "a folder containing the home folder")
        #expect(kinds("/").contains(.systemLocation))
        #expect(kinds("/usr/local").contains(.systemLocation))
        #expect(kinds("/etc").contains(.systemLocation))
        #expect(kinds("/Users").contains(.systemLocation))
        #expect(kinds("/Volumes").contains(.systemLocation))
        #expect(kinds(home + "/.ssh").contains(.sensitive))
        #expect(kinds(home + "/Library/Keys").contains(.sensitive), "inside ~/Library")
    }

    @Test func missingFilesRelativeAndLinksAreReported() {
        #expect(kinds(home + "/nope") == [.missing])
        #expect(kinds(home + "/file.txt") == [.notDirectory])
        #expect(kinds("Documents/Repos") == [.notAbsolute])
        let link = CodeRoots.issues(for: home + "/repos-link", home: home, sharedPrefixes: shared)
        #expect(link.first?.kind == .notCanonical)
        #expect(link.first?.suggestion == home + "/Documents/Repos", "the fix is the real folder")
        // A link that leads to a system location is refused for where it leads.
        #expect(kinds(home + "/Documents/Repos/evil").contains(.systemLocation))
    }

    @Test func foldersRancherDoesNotShareSayHowToAddThem() {
        let issues = CodeRoots.issues(for: home + "/plain", home: home, sharedPrefixes: ["/somewhere-else"])
        let notShared = try? #require(issues.first { $0.kind == .notShared })
        #expect(notShared?.message.contains("override.yaml") == true)
        #expect(notShared?.message.contains("restart Rancher Desktop") == true)
    }

    @Test func overlappingRootsKeepTheOutermostAndAreSorted() {
        let validation = CodeRoots.validate([home + "/work", home + "/Documents/Repos/a", home + "/Documents/Repos", home + "/work"],
                                            home: home, sharedPrefixes: shared)
        #expect(validation.roots == [home + "/Documents/Repos", home + "/work"])
        #expect(validation.issues.map(\.kind) == [.overlaps])
        #expect(validation.isValid, "an overlap is dropped, not an error")
        let bad = CodeRoots.validate([home, home + "/work"], home: home, sharedPrefixes: shared)
        #expect(bad.roots == [home + "/work"])
        #expect(!bad.isValid)
    }

    @Test func suggestionIsTheFolderHoldingTheProjects() {
        let suggestion = CodeRoots.suggestion(projectDirectories: [home + "/Documents/Repos/a", home + "/Documents/Repos/b"],
                                              home: home, sharedPrefixes: shared)
        #expect(suggestion == [home + "/Documents/Repos"])
        let two = CodeRoots.suggestion(projectDirectories: [home + "/Documents/Repos/a", home + "/work/x"], home: home, sharedPrefixes: shared)
        #expect(two == [home + "/Documents/Repos", home + "/work"])
    }

    @Test func suggestionNeverHomeRootOrABroadFolder() {
        // A project directly in the home folder or in ~/Documents suggests itself, not its parent.
        let suggestion = CodeRoots.suggestion(projectDirectories: [home + "/plain", home + "/Documents/solo"], home: home, sharedPrefixes: shared)
        #expect(suggestion == [home + "/Documents/solo", home + "/plain"])
        #expect(!suggestion.contains(home))
        #expect(CodeRoots.suggestion(projectDirectories: [], home: home, sharedPrefixes: shared).isEmpty)
        // A project in a system location suggests nothing.
        #expect(CodeRoots.suggestion(projectDirectories: ["/usr/local/src"], home: home, sharedPrefixes: shared).isEmpty)
    }

    @Test func rootContainingResolvesLinksAndPicksTheLongest() {
        let roots = [home + "/Documents/Repos", home + "/Documents/Repos/a"]
        #expect(CodeRoots.root(containing: home + "/Documents/Repos/a/src", in: roots) == home + "/Documents/Repos/a")
        #expect(CodeRoots.root(containing: home + "/repos-link/b", in: roots) == home + "/Documents/Repos")
        #expect(CodeRoots.root(containing: home + "/work", in: roots) == nil)
    }

    @Test func managedPolicyReadsRootsLockAndModes() {
        let managed = ManagedExecutionPolicy.managed(from: { key in
            switch key {
            case ManagedExecutionPolicy.codeRootsKey: ["~/Documents/Repos"]
            case ManagedExecutionPolicy.codeRootsLockedKey: true
            case ManagedExecutionPolicy.defaultModeKey: "project"
            case ManagedExecutionPolicy.allowedModesKey: ["project", "shared", "bogus"]
            default: nil
            }
        }, source: "test", home: home)
        #expect(managed.codeRoots == [home + "/Documents/Repos"])
        #expect(managed.codeRootsLocked)
        #expect(managed.defaultMode == .projectContainer)
        #expect(managed.allows(.sharedWorkspace) && !managed.allows(.hostDocker))
        #expect(ManagedExecutionPolicy.read(defaults: UserDefaults(suiteName: "bc-\(UUID())")!, systemPlist: "/nonexistent") == nil)
    }
}
