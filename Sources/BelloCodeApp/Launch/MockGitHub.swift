import Engine
import Foundation

/// Recorded GitHub answers for mock mode and the `extras` snapshots: one open PR with a running and a failed check,
/// a review, and the branch lookup (no network; docs/features/orchestration-extras.md).
enum MockGitHub {
    static let ref = PullRequestRef(owner: "acme", repo: "rocket", number: 128)
    static let secondRef = PullRequestRef(owner: "acme", repo: "rocket", number: 131)

    static func transport() -> FixtureGitHubTransport {
        let transport = FixtureGitHubTransport(access: .cli)
        install(transport, ref: ref, title: "Parser: precedence climbing for binary operators", sha: "9f2c1ab", branch: "parser/precedence",
            checks: [("build (macos-15)", "completed", "success"), ("unit tests", "in_progress", nil), ("lint", "completed", "success"), ("docs preview", "queued", nil)],
            reviews: #"[{"id":7001,"user":{"login":"mara"},"state":"CHANGES_REQUESTED"}]"#, comments: 3, reviewComments: 4)
        install(transport, ref: secondRef, title: "Docs: 2.0 migration guide", sha: "77aa310", branch: "docs/migration",
            checks: [("build (macos-15)", "completed", "success"), ("lint", "completed", "success")],
            reviews: #"[{"id":7010,"user":{"login":"lee"},"state":"APPROVED"}]"#, comments: 1, reviewComments: 0)
        return transport
    }

    /// The same PR after its checks finished (one failure): what a watch wakes on.
    static func finish(_ transport: FixtureGitHubTransport) {
        install(transport, ref: ref, title: "Parser: precedence climbing for binary operators", sha: "9f2c1ab", branch: "parser/precedence",
            checks: [("build (macos-15)", "completed", "success"), ("unit tests", "completed", "failure"), ("lint", "completed", "success"), ("docs preview", "completed", "success")],
            reviews: #"[{"id":7001,"user":{"login":"mara"},"state":"CHANGES_REQUESTED"}]"#, comments: 3, reviewComments: 4)
    }

    static func install(
        _ transport: FixtureGitHubTransport, ref: PullRequestRef, title: String, sha: String, branch: String,
        checks: [(String, String, String?)], reviews: String, comments: Int, reviewComments: Int
    ) {
        let base = "repos/\(ref.owner)/\(ref.repo)"
        transport.setJSON(
            "\(base)/pulls/\(ref.number)",
            #"{"number":\#(ref.number),"title":"\#(title)","state":"open","merged":false,"draft":false,"head":{"sha":"\#(sha)","ref":"\#(branch)"},"base":{"ref":"main"},"user":{"login":"octo"},"comments":\#(comments),"review_comments":\#(reviewComments),"mergeable":true}"#)
        let runs = checks.enumerated().map { index, run in
            #"{"id":\#(ref.number * 100 + index),"name":"\#(run.0)","status":"\#(run.1)","conclusion":\#(run.2.map { "\"\($0)\"" } ?? "null"),"html_url":"https://github.com/\#(ref.slug)/actions/runs/\#(index)"}"#
        }
        transport.setJSON("\(base)/commits/\(sha)/check-runs?per_page=100", #"{"total_count":\#(runs.count),"check_runs":[\#(runs.joined(separator: ","))]}"#)
        transport.setJSON("\(base)/pulls/\(ref.number)/reviews?per_page=100", reviews)
    }
}
