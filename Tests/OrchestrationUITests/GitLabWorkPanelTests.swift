import BelloCore
import Engine
import Foundation
import Testing

@testable import OrchestrationUI

/// GitLab 2 in the Merge Requests tab: the Issues section resolves the project, lists and selects issues, Start Thread
/// hands the issue (and a selection) to the app, Link to This Thread links it; the To-dos section lists, opens a linked
/// MR in place and marks done only with writes on; approvals, dependencies and Code Owners load with an MR.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct GitLabWorkPanelTests {
    static let instance = MergeRequestPanelModelTests.instance
    let thread = SessionID("ses_panel")

    final class IssueHost: GitLabWorkHost {
        var links: [SessionID: [LinkedIssue]] = [:]
        func writeIssueLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedIssue]) -> [LinkedIssue]) async throws -> [LinkedIssue] {
            let updated = transform(links[sessionID] ?? [])
            links[sessionID] = updated
            return updated
        }
    }

    let host = IssueHost()

    func make() async throws -> (MergeRequestPanelModel, FakeGitLabServer) {
        let (base, server, _) = try await MergeRequestPanelModelTests().make()
        server.edit("team/app") { project in
            project.issues[3] = FakeGitLabServer.Issue(iid: 3, title: "Crash on launch", description: "It crashes.", assignees: ["me"])
            project.issues[4] = FakeGitLabServer.Issue(iid: 4, title: "Typo", assignees: ["mara"])
        }
        server.addTodo(FakeGitLabServer.Todo(id: 9, action: "review_requested", targetType: "MergeRequest", targetIID: 5, projectPath: "team/app"))
        server.addTodo(FakeGitLabServer.Todo(id: 10, action: "assigned", targetType: "Issue", targetIID: 3, projectPath: "team/app"))
        let work = GitLabWorkService(mergeRequests: base.service)
        work.host = host
        server.editMR("team/app", 5) { $0.diffs = [("Sources/a.swift", "Sources/a.swift", "@@ -1 +1 @@\n-a\n+b\n")] }
        let model = MergeRequestPanelModel(service: base.service, work: work, reviews: MergeRequestReviewService(mergeRequests: base.service, store: try ProjectionStore(location: .inMemory)))
        model.projectDirectory = { "/tmp/team-app" }
        model.resolveProject = { _ in ForgeProject(instance: Self.instance, projectPath: "team/app") }
        model.display(thread)
        return (model, server)
    }

    @Test func issuesListSelectStartThreadAndLink() async throws {
        let (model, _) = try await make()
        model.section = .issues
        await model.loadIssues()
        #expect(model.issueList?.issues.map(\.iid) == [3], "assigned to me")
        let issue = try #require(model.issueList?.issues.first)
        await model.selectIssue(issue)
        #expect(model.issueDetail?.description == "It crashes.")
        var started: [(GitLabIssue, String, String?)] = []
        model.startThreadFromIssue = { started.append(($0, $1, $2)) }
        model.startThread(issue, selection: "crashes")
        #expect(started.count == 1 && started[0].0.description == "It crashes." && started[0].1 == Self.instance.baseURL && started[0].2 == "crashes")
        await model.linkIssue(issue)
        #expect(model.linkedIssues.map(\.reference) == ["team/app#3"])
        model.issueFilter = .all
        await model.loadIssues()
        #expect(model.issueList?.issues.map(\.iid) == [4, 3])
        // A folder that is not on a configured instance says so instead of a blank list.
        model.resolveProject = { _ in nil }
        await model.loadIssues()
        #expect(model.issueProblem?.contains("not on a configured GitLab instance") == true)
    }

    /// NF18: with the Issues section showing, a thread of another project drops the open issue and lists that
    /// project's issues.
    @Test func issuesFollowTheDisplayedProject() async throws {
        let (model, server) = try await make()
        server.put(FakeGitLabServer.Project(id: 12, path: "team/other"))
        server.edit("team/other") { $0.issues[8] = FakeGitLabServer.Issue(iid: 8, title: "Other project bug", assignees: ["me"]) }
        model.section = .issues
        await model.loadIssues()
        let issue = try #require(model.issueList?.issues.first)
        await model.selectIssue(issue)
        #expect(model.issueDetail != nil)
        var directory = "/tmp/team-app"
        model.projectDirectory = { directory }
        model.resolveProject = { folder in
            ForgeProject(instance: Self.instance, projectPath: folder == "/tmp/team-other" ? "team/other" : "team/app")
        }
        directory = "/tmp/team-other"
        model.display(SessionID("ses_other"))
        #expect(model.selectedIssue == nil, "the other project's issue is closed")
        #expect(model.issueDetail == nil)
        await model.issueReload?.value
        #expect(model.issueProject?.projectPath == "team/other")
        #expect(model.issueList?.issues.map(\.iid) == [8])
    }

    @Test func todosOpenInPlaceAndMarkDoneNeedsWrites() async throws {
        let (model, server) = try await make()
        model.section = .todos
        await model.loadTodos()
        #expect(model.todos.map(\.todo.id).sorted() == [9, 10])
        let review = try #require(model.todos.first { $0.todo.id == 9 })
        var opened: [URL] = []
        model.openURL = { url, _ in opened.append(url) }
        model.openTodo(review.todo)
        #expect(model.section == .mergeRequests && model.expandedURL == MergeRequestPanelModelTests.ref.url && opened.isEmpty, "a linked MR opens in place")
        let issue = try #require(model.todos.first { $0.todo.id == 10 })
        model.openTodo(issue.todo)
        #expect(opened.map(\.absoluteString) == ["https://gitlab.corp.test/team/app/-/issues/3"])
        await model.markDone(review.todo, instance: review.instance)
        #expect(model.message?.contains("write actions are off") == true)
        #expect(!server.requests.contains { $0.method == "POST" })
        await model.service.setSettings(GitLabInstanceSettings(writesEnabled: true), for: Self.instance.baseURL)
        await model.markDone(review.todo, instance: review.instance)
        #expect(model.todos.map(\.todo.id) == [10] && model.notice?.contains("Marked") == true)
    }

    @Test func expandingLoadsApprovalsAndDependencies() async throws {
        let (model, _) = try await make()
        await model.loadDetails(MergeRequestPanelModelTests.ref)
        #expect(model.work?.approvalExplanations[MergeRequestPanelModelTests.ref.url]?.lines.isEmpty == false)
        #expect(model.work?.dependencies[MergeRequestPanelModelTests.ref.url] != nil)
        #expect(model.work?.codeOwnersNotes[MergeRequestPanelModelTests.ref.url] != nil, "/tmp/team-app is no checkout: the note says why")
    }
}
