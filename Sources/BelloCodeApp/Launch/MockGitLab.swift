import BelloCore
import Engine
import Foundation

/// The GitLab of mock mode and the `extras`/`gitlab` snapshots (no network; docs/features/gitlab.md): an in-process
/// `FakeGitLabServer` for a self-managed instance with a path prefix (`https://code.example.test/gitlab`), one open MR
/// with a running pipeline and a review in progress, a second approved one. The mock token lives in memory only.
enum MockGitLab {
    static let instance = GitLabInstance(baseURL: "https://code.example.test/gitlab")!
    static let project = "platform/rocket"
    static let ref = MergeRequestRef(instance: instance.baseURL, projectPath: project, iid: 128)
    static let secondRef = MergeRequestRef(instance: instance.baseURL, projectPath: project, iid: 131)
    static let token = "mock-token-not-real"

    static func tokens() -> InMemorySecretVault {
        let vault = InMemorySecretVault()
        try? vault.store(account: instance.baseURL, label: "mock", value: SecretValue(token))
        return vault
    }

    static let unitLog = """
        \u{1B}[0KRunning with gitlab-runner 17.4.0 (b92ee590)\u{1B}[0;m
        \u{1B}[0K  on shared-macos-arm64 Zx8kQ2, system ID: s_7f1e9a\u{1B}[0;m
        section_start:1731830400:prepare_script\r\u{1B}[0K\u{1B}[0K\u{1B}[36;1mPreparing environment\u{1B}[0;m
        Running on runner-zx8kq2 via mac-mini-07...
        section_end:1731830404:prepare_script\r\u{1B}[0K
        section_start:1731830404:get_sources\r\u{1B}[0K\u{1B}[0K\u{1B}[36;1mGetting source from Git repository\u{1B}[0;m
        \u{1B}[32;1mFetching changes with git depth set to 20...\u{1B}[0;m
        Checking out 9f2c1ab4 as detached HEAD (ref is parser/precedence)...
        section_end:1731830411:get_sources\r\u{1B}[0K
        section_start:1731830411:step_script\r\u{1B}[0K\u{1B}[0K\u{1B}[36;1mExecuting "step_script" stage of the job script\u{1B}[0;m
        \u{1B}[32;1m$ swift test --parallel\u{1B}[0;m
        Building for debugging...
        [412/412] Linking RocketPackageTests
        Build complete! (38.21s)
        Test Suite 'All tests' started at 2026-11-18 09:41:07.112
        Test Suite 'ParserTests' started
        Test Case '-[ParserTests testUnaryMinus]' passed (0.003 seconds).
        Test Case '-[ParserTests testAssociativity]' started.
        /builds/platform/rocket/Tests/ParserTests/PrecedenceTests.swift:88: error: -[ParserTests testAssociativity] : XCTAssertEqual failed: ("(2 ^ (3 ^ 2))") is not equal to ("((2 ^ 3) ^ 2)")
        Test Case '-[ParserTests testAssociativity]' failed (0.004 seconds).
        Test Case '-[ParserTests testPrecedenceTable]' passed (0.002 seconds).
        Test Suite 'ParserTests' failed at 2026-11-18 09:41:07.410.
        \u{1B}[31;1m	 Executed 212 tests, with 1 failure (0 unexpected) in 4.118 (4.204) seconds\u{1B}[0;m
        section_end:1731830480:step_script\r\u{1B}[0K
        section_start:1731830480:cleanup_file_variables\r\u{1B}[0K\u{1B}[0K\u{1B}[36;1mCleaning up project directory and file based variables\u{1B}[0;m
        section_end:1731830481:cleanup_file_variables\r\u{1B}[0K
        \u{1B}[31;1mERROR: Job failed: exit status 1
        \u{1B}[0;m
        """

    static func transport() -> FakeGitLabServer {
        var options = FakeGitLabServer.Options()
        options.version = "17.4.1"
        let server = FakeGitLabServer(instance: instance, token: token, username: "mock-user", options: options)
        var rocket = FakeGitLabServer.Project(id: 4_201, path: project)
        rocket.branches = ["main", "release/2.0", "parser/precedence", "docs/migration", "parser/error-recovery"]
        rocket.members = [
            GitLabUserRef(id: 31, username: "mara", name: "Mara Lind"), GitLabUserRef(id: 32, username: "lee", name: "Lee Park"),
            GitLabUserRef(id: 33, username: "octo", name: "Octo Cat"),
        ]
        var first = FakeGitLabServer.MR(iid: 128, title: "Parser: precedence climbing for binary operators", source: "parser/precedence")
        first.author = "octo"
        first.labels = ["parser", "performance"]
        first.assignees = ["octo"]
        first.reviewers = ["mara", "lee"]
        first.approvedBy = ["mara"]
        first.approvalsRequired = 2
        first.pipelineID = 9_101
        first.pipelineStatus = "running"
        first.updatedAt = "2026-11-18T09:38:00Z"
        first.discussions = [
            .init(id: "c1a", notes: [
                .init(id: 501, author: "mara", body: "Right-associative `^` needs its own binding power; `2 ^ 3 ^ 2` should be 512.", position: ("Sources/Parser/Precedence.swift", 64)),
                .init(id: 502, author: "octo", body: "Good catch, adding a test."),
            ]),
            .init(id: "c2b", notes: [.init(id: 503, author: "lee", body: "Can we keep the old entry point as a deprecated wrapper for one release?")]),
            .init(id: "c3c", notes: [.init(id: 504, author: "mara", body: "Benchmarks look great.", resolvable: true, resolved: true)]),
        ]
        rocket.mrs[128] = first
        rocket.jobs[9_101] = [
            .init(id: 91_011, name: "build", stage: "build", status: "success"),
            .init(id: 91_012, name: "unit-tests", stage: "test", status: "running"),
            .init(id: 91_013, name: "lint", stage: "test", status: "success"),
            .init(id: 91_014, name: "docs-preview", stage: "deploy", status: "manual"),
        ]
        rocket.traces[91_012] = unitLog
        rocket.traces[91_011] = "\u{1B}[32;1m$ swift build -c release\u{1B}[0;m\nBuild complete! (61.02s)\n\u{1B}[32;1mJob succeeded\u{1B}[0;m"
        var second = FakeGitLabServer.MR(iid: 131, title: "Docs: 2.0 migration guide", source: "docs/migration")
        second.approvedBy = ["lee"]
        second.approvalsRequired = 1
        second.pipelineID = 9_107
        second.pipelineStatus = "success"
        rocket.mrs[131] = second
        rocket.jobs[9_107] = [.init(id: 91_071, name: "build", stage: "build", status: "success"), .init(id: 91_072, name: "lint", stage: "test", status: "success")]
        server.put(rocket)
        return server
    }

    /// MR !128 after its pipeline finished with `unit-tests` failed: what a babysit wakes on.
    static func finish(_ server: FakeGitLabServer) {
        server.editMR(project, 128) { $0.pipelineStatus = "failed" }
        server.edit(project) { project in
            project.jobs[9_101] = project.jobs[9_101]?.map { job in
                var job = job
                if job.name == "unit-tests" {
                    job.status = "failed"
                    job.failureReason = "script_failure"
                }
                if job.name == "docs-preview" { job.status = "manual" }
                return job
            }
        }
    }

    // MARK: GitLab 2 (`--snapshot gitlab2`)

    static let precedenceV1 = """
        @@ -58,10 +58,11 @@ struct PrecedenceParser {
             func bindingPower(of op: Token) -> (left: Int, right: Int)? {
                 switch op.kind {
        -        case .plus, .minus: return (1, 2)
        -        case .star, .slash: return (3, 4)
        +        case .plus, .minus: return (10, 11)
        +        case .star, .slash: return (20, 21)
        +        case .caret: return (30, 31)
                 default: return nil
                 }
             }
         
             mutating func parseExpression(minimum: Int = 0) throws -> Expr {
                 var lhs = try parsePrefix()

        """
    static let precedenceV2 = """
        @@ -58,10 +58,12 @@ struct PrecedenceParser {
             func bindingPower(of op: Token) -> (left: Int, right: Int)? {
                 switch op.kind {
        -        case .plus, .minus: return (1, 2)
        -        case .star, .slash: return (3, 4)
        +        case .plus, .minus: return (10, 11)
        +        case .star, .slash: return (20, 21)
        +        // Right-associative: the right binding power is lower.
        +        case .caret: return (31, 30)
                 default: return nil
                 }
             }
         
             mutating func parseExpression(minimum: Int = 0) throws -> Expr {
                 var lhs = try parsePrefix()

        """
    static let testsV2 = """
        @@ -0,0 +1,8 @@
        +import Testing
        +@testable import Rocket
        +
        +@Test func exponentIsRightAssociative() throws {
        +    #expect(try evaluate("2 ^ 3 ^ 2") == 512)
        +}
        +
        +@Test func unaryMinusBindsTighter() throws { #expect(try evaluate("-2 ^ 2") == 4) }

        """

    /// Review data on MR !128: two diff versions, a current thread on the new `^` line, an outdated thread from the first
    /// version, a resolved thread in the new test file; issues of the project; to-dos; Premium approval rules.
    static func addReview(_ server: FakeGitLabServer) {
        let v1 = FakeGitLabServer.Version(
            id: 7_001, base: "4e1d2c3b4a5f6e7d", start: "4e1d2c3b4a5f6e7d", head: "71c0d2e9a8b3c4d5",
            diffs: [("Sources/Parser/Precedence.swift", "Sources/Parser/Precedence.swift", precedenceV1)])
        let v2 = FakeGitLabServer.Version(
            id: 7_002, base: "4e1d2c3b4a5f6e7d", start: "4e1d2c3b4a5f6e7d", head: "9f2c1ab4e5d6",
            diffs: [("Sources/Parser/Precedence.swift", "Sources/Parser/Precedence.swift", precedenceV2), ("", "Tests/ParserTests/PrecedenceTests.swift", testsV2)])
        func position(_ version: FakeGitLabServer.Version, _ path: String, new: Int?, old: Int? = nil) -> FakeGitLabServer.Position {
            FakeGitLabServer.Position(base: version.base, start: version.start, head: version.head, oldPath: path, newPath: path, oldLine: old, newLine: new)
        }
        func note(_ id: Int, _ author: String, _ body: String, _ position: FakeGitLabServer.Position?, resolved: Bool = false, created: String) -> FakeGitLabServer.Note {
            var note = FakeGitLabServer.Note(id: id, author: author, body: body, resolvable: true, resolved: resolved)
            note.diffPosition = position
            note.created = created
            return note
        }
        server.update {
            $0.version = "17.4.1-ee"
            $0.approvalRules = true
            $0.dependencies = true
        }
        server.editMR(project, 128) { mr in
            mr.versions = [v1, v2]
            mr.sha = v2.head
            mr.diffs = v2.diffs
            mr.eligibleApprovers = ["mara", "lee", "octo"]
            mr.hiddenGroups = true
            mr.blockedBy = [131]
            let caret = position(v2, "Sources/Parser/Precedence.swift", new: 63)
            mr.discussions = [
                .init(id: "c1a", notes: [
                    note(501, "mara", "Right-associative `^` needs its own binding power; `2 ^ 3 ^ 2` should be 512, not 64.", caret, created: "2026-11-18T08:12:00Z"),
                    note(502, "octo", "Good catch: the right power is now lower than the left. Added a test.", caret, created: "2026-11-18T08:40:00Z"),
                ]),
                .init(id: "c0d", notes: [
                    note(505, "lee", "Should `^` share the multiplicative powers?", position(v1, "Sources/Parser/Precedence.swift", new: 62), created: "2026-11-17T16:05:00Z"),
                ]),
                .init(id: "c4e", notes: [
                    note(506, "lee", "Nice: a test for unary minus too.", position(v2, "Tests/ParserTests/PrecedenceTests.swift", new: 8), resolved: true, created: "2026-11-18T09:02:00Z"),
                ]),
                .init(id: "c2b", notes: [.init(id: 503, author: "lee", body: "Can we keep the old entry point as a deprecated wrapper for one release?")]),
            ]
        }
        server.edit(project) { project in
            let issues: [(Int, String, [String], [String])] = [
                (212, "Exponent operator is left-associative", ["mock-user"], ["parser", "bug"]),
                (215, "Parse errors should name the expected token", ["mock-user"], ["parser"]),
                (219, "Benchmark the precedence climber on large inputs", ["mock-user", "mara"], ["performance"]),
                (220, "Document operator precedence in the 2.0 guide", ["mock-user"], ["docs"]),
            ]
            for (iid, title, assignees, labels) in issues {
                var issue = FakeGitLabServer.Issue(iid: iid, title: title, assignees: assignees)
                issue.labels = labels
                issue.updatedAt = "2026-11-1\(iid % 8)T10:00:00Z"
                project.issues[iid] = issue
            }
            project.issues[212]?.description = """
                `2 ^ 3 ^ 2` evaluates to 64; it should be 512 (exponentiation is right-associative).

                Steps:
                1. `rocket eval "2 ^ 3 ^ 2"`
                2. Expected 512, got 64.

                Probably the binding powers in `Precedence.swift`.
                """
            project.issues[212]?.relatedMRs = [128]
        }
        server.addTodo(FakeGitLabServer.Todo(id: 8_001, action: "review_requested", targetType: "MergeRequest", targetIID: 131, projectPath: project))
        server.addTodo(FakeGitLabServer.Todo(id: 8_002, action: "mentioned", targetType: "Issue", targetIID: 215, projectPath: project, body: "@mock-user can you take this?"))
        server.addTodo(FakeGitLabServer.Todo(id: 8_003, action: "build_failed", targetType: "MergeRequest", targetIID: 128, projectPath: project))
        server.addTodo(FakeGitLabServer.Todo(id: 8_004, action: "assigned", targetType: "Issue", targetIID: 220, projectPath: project))
        server.addTodo(FakeGitLabServer.Todo(id: 8_005, action: "approval_required", targetType: "MergeRequest", targetIID: 131, projectPath: project))
    }
}
