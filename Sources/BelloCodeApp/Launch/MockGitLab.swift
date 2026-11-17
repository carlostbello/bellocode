import BelloCore
import Engine
import Foundation

/// Recorded GitLab answers for mock mode and the `extras` snapshots (no network; docs/features/orchestration-extras.md):
/// a self-managed instance with a path prefix (`https://code.example.test/gitlab`), one open MR with a running pipeline
/// and a review in progress, a second approved one. The mock token lives in memory only.
enum MockGitLab {
    static let instance = GitLabInstance(baseURL: "https://code.example.test/gitlab")!
    static let project = "platform/rocket"
    static let ref = MergeRequestRef(instance: instance.baseURL, projectPath: project, iid: 128)
    static let secondRef = MergeRequestRef(instance: instance.baseURL, projectPath: project, iid: 131)
    static var api: String { instance.apiBase + "/projects/platform%2Frocket" }

    static func tokens() -> InMemorySecretVault {
        let vault = InMemorySecretVault()
        try? vault.store(account: instance.baseURL, label: "mock", value: SecretValue("mock-token-not-real"))
        return vault
    }

    static func transport() -> FixtureForgeTransport {
        let transport = FixtureForgeTransport()
        transport.setJSON(instance.apiBase + "/user", #"{"username":"mock-user"}"#)
        install(
            transport, iid: 128, title: "Parser: precedence climbing for binary operators", branch: "parser/precedence", pipeline: 9101,
            pipelineStatus: "running",
            jobs: [("build", "build", "success"), ("unit-tests", "test", "running"), ("lint", "test", "success"), ("docs-preview", "deploy", "pending")],
            approvals: #"{"approved":false,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"username":"mara"}}]}"#, notes: 7, unresolved: 2)
        install(
            transport, iid: 131, title: "Docs: 2.0 migration guide", branch: "docs/migration", pipeline: 9107, pipelineStatus: "success",
            jobs: [("build", "build", "success"), ("lint", "test", "success")],
            approvals: #"{"approved":true,"approvals_required":1,"approvals_left":0,"approved_by":[{"user":{"username":"lee"}}]}"#, notes: 1, unresolved: 0)
        return transport
    }

    /// MR !128 after its pipeline finished with one failed job: what a watch wakes on.
    static func finish(_ transport: FixtureForgeTransport) {
        install(
            transport, iid: 128, title: "Parser: precedence climbing for binary operators", branch: "parser/precedence", pipeline: 9101,
            pipelineStatus: "failed",
            jobs: [("build", "build", "success"), ("unit-tests", "test", "failed"), ("lint", "test", "success"), ("docs-preview", "deploy", "skipped")],
            approvals: #"{"approved":false,"approvals_required":2,"approvals_left":1,"approved_by":[{"user":{"username":"mara"}}]}"#, notes: 7, unresolved: 2)
    }

    static func install(
        _ transport: FixtureForgeTransport, iid: Int, title: String, branch: String, pipeline: Int, pipelineStatus: String,
        jobs: [(String, String, String)], approvals: String, notes: Int, unresolved: Int
    ) {
        let web = "\(instance.baseURL)/\(project)/-/merge_requests/\(iid)"
        transport.setJSON(
            "\(api)/merge_requests/\(iid)",
            #"{"iid":\#(iid),"title":"\#(title)","state":"opened","draft":false,"source_branch":"\#(branch)","target_branch":"main","author":{"username":"octo"},"sha":"9f2c1ab","web_url":"\#(web)","user_notes_count":\#(notes),"head_pipeline":{"id":\#(pipeline),"status":"\#(pipelineStatus)","web_url":"\#(instance.baseURL)/\#(project)/-/pipelines/\#(pipeline)"}}"#)
        transport.setJSON("\(api)/merge_requests/\(iid)/approvals", approvals)
        let items = jobs.enumerated().map { index, job in
            #"{"id":\#(pipeline * 10 + index),"name":"\#(job.0)","stage":"\#(job.1)","status":"\#(job.2)","web_url":"\#(instance.baseURL)/\#(project)/-/jobs/\#(pipeline * 10 + index)"}"#
        }
        transport.setJSON("\(api)/pipelines/\(pipeline)/jobs?per_page=100", "[" + items.joined(separator: ",") + "]")
        let discussions = (0..<unresolved).map { #"{"id":"d\#($0)","notes":[{"id":\#($0),"resolvable":true,"resolved":false,"system":false}]}"# }
        transport.setJSON("\(api)/merge_requests/\(iid)/discussions?per_page=100", "[" + discussions.joined(separator: ",") + "]")
    }
}
