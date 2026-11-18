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
}
