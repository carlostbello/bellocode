import BelloCore
import Foundation
import Observation

/// What the work service needs from the engine: issue links in session metadata.
@MainActor
public protocol GitLabWorkHost: AnyObject {
    /// Replaces the thread's linked issues in its metadata (other keys kept).
    func writeIssueLinks(_ sessionID: SessionID, _ transform: @escaping @Sendable ([LinkedIssue]) -> [LinkedIssue]) async throws -> [LinkedIssue]
}

/// Issues, to-dos, approval explanations, dependent MRs and Code Owners (GitLab 2, docs/features/gitlab.md). Shares
/// the instances, capabilities, token handling and request discipline of `MergeRequestService`.
///
/// Threading: `@MainActor` state; HTTP and parsing off the main actor in `GitLabProvider`; git through `GitRepository`.
@MainActor
@Observable
public final class GitLabWorkService {
    public struct IssueList: Hashable, Sendable {
        public var filter: IssueFilter
        public var search: String
        public var issues: [GitLabIssue]
        public var nextPage: Int?
        /// The paging bound cut the list ("more on GitLab").
        public var bounded: Bool
        public var loaded: Date
    }

    public struct TodoList: Hashable, Sendable {
        public var todos: [GitLabTodo]
        public var truncated: Bool
        public var loaded: Date
    }

    /// Per "instance|project": the last list (kept, marked with its time, while reloading or after a failure).
    public private(set) var issueLists: [String: IssueList] = [:]
    public private(set) var issueProblems: [String: String] = [:]
    public private(set) var issueLoading: Set<String> = []
    /// Per issue URL: the issue with its description, and its related MRs (nil: not offered by the instance).
    public private(set) var issueDetails: [String: GitLabIssue] = [:]
    public private(set) var relatedMergeRequests: [String: [RelatedMergeRequest]] = [:]
    /// Per thread: linked issues (session metadata `bellocode_issues`).
    public private(set) var issueLinks: [SessionID: [LinkedIssue]] = [:]
    /// Per instance base URL.
    public private(set) var todoLists: [String: TodoList] = [:]
    public private(set) var todoProblems: [String: String] = [:]
    /// Per MR URL.
    public private(set) var approvalExplanations: [String: ApprovalExplanation] = [:]
    public private(set) var dependencies: [String: MergeRequestDependencies] = [:]
    public private(set) var codeOwners: [String: CodeOwnersSummary] = [:]
    /// Per MR URL: why Code Owners are not shown ("No CODEOWNERS file in the repository").
    public private(set) var codeOwnersNotes: [String: String] = [:]

    public static let todoTTL: TimeInterval = 120
    static let maxCachedDetails = 100

    @ObservationIgnored public let mergeRequests: MergeRequestService
    @ObservationIgnored public weak var host: (any GitLabWorkHost)?
    @ObservationIgnored private var projectIDs: [String: Int] = [:]
    @ObservationIgnored private var issueGenerations: [String: Int] = [:]

    public init(mergeRequests: MergeRequestService) {
        self.mergeRequests = mergeRequests
    }

    var provider: GitLabProvider { mergeRequests.provider }
    var now: Date { mergeRequests.clock.now() }

    public static func key(_ project: ForgeProject) -> String { project.instance.baseURL + "|" + project.projectPath }

    // MARK: Issues

    /// Loads the first page (or, with `more`, the next page) of the project's issues for `filter` and `search`.
    public func loadIssues(_ project: ForgeProject, filter: IssueFilter, search: String, more: Bool = false) async {
        let key = Self.key(project)
        let previous = issueLists[key]
        let sameQuery = previous?.filter == filter && previous?.search == search
        let page = more && sameQuery ? (previous?.nextPage ?? 1) : 1
        if more, sameQuery, previous?.nextPage == nil { return }
        let generation = (issueGenerations[key] ?? 0) + 1
        issueGenerations[key] = generation
        issueLoading.insert(key)
        defer { if issueGenerations[key] == generation { issueLoading.remove(key) } }
        do {
            let id = filter == .mentioned ? try await projectID(project) : nil
            let result = try await provider.issues(project, filter: filter, search: search, page: page, projectID: id)
            guard issueGenerations[key] == generation else { return }
            let earlier = page > 1 ? previous?.issues ?? [] : []
            var seen = Set(earlier.map(\.iid))
            let merged = earlier + result.issues.filter { seen.insert($0.iid).inserted }
            issueLists[key] = IssueList(filter: filter, search: search, issues: merged, nextPage: result.nextPage, bounded: result.bounded, loaded: now)
            issueProblems[key] = nil
        } catch {
            guard issueGenerations[key] == generation else { return }
            issueProblems[key] = (error as? ForgeError)?.description ?? ExtrasError.message(error)
        }
    }

    func projectID(_ project: ForgeProject) async throws -> Int {
        let key = Self.key(project)
        if let id = projectIDs[key] { return id }
        let id = try await provider.project(project).id
        projectIDs[key] = id
        return id
    }

    /// The issue with its description and related MRs (when the instance offers them).
    @discardableResult
    public func loadIssue(_ project: ForgeProject, iid: Int) async throws -> GitLabIssue {
        let issue = try await provider.issue(project, iid: iid)
        if issueDetails.count >= Self.maxCachedDetails { issueDetails.removeAll() }
        issueDetails[issue.webURL] = issue
        let instance = project.instance.baseURL
        if mergeRequests.capabilities(instance).support(.relatedMergeRequests).mayTry {
            do {
                relatedMergeRequests[issue.webURL] = try await provider.relatedMergeRequests(project, iid: iid)
                mergeRequests.recordProbe(instance, .relatedMergeRequests, true)
            } catch ForgeError.notFound {
                mergeRequests.recordProbe(instance, .relatedMergeRequests, false)
            } catch {}
        }
        return issue
    }

    // MARK: Issue links

    public func ingest(_ sessions: [Session]) {
        for session in sessions {
            let list = LinkedIssue.decode(fromMetadata: session.metadata)
            if list.isEmpty { if issueLinks[session.id] != nil { issueLinks[session.id] = nil } } else if issueLinks[session.id] != list { issueLinks[session.id] = list }
        }
    }

    public func removed(_ ids: Set<SessionID>) { for id in ids { issueLinks[id] = nil } }

    public func issues(for id: SessionID) -> [LinkedIssue] { issueLinks[id] ?? [] }

    /// Links an issue to a thread (shown in the header). Idempotent.
    public func link(_ issue: GitLabIssue, instance: String, to id: SessionID) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        let link = LinkedIssue(issue, instance: instance, linked: now)
        issueLinks[id] = try await host.writeIssueLinks(id) { current in
            current.contains { $0.webURL == link.webURL } ? current : current + [link]
        }
    }

    public func unlink(_ issue: LinkedIssue, from id: SessionID) async throws {
        guard let host else { throw ExtrasError("BelloCode is not connected.") }
        issueLinks[id] = try await host.writeIssueLinks(id) { $0.filter { $0.webURL != issue.webURL } }
    }

    // MARK: To-dos

    /// The token user's pending to-dos on `instance` (cached for `todoTTL` unless `force`).
    public func loadTodos(_ instance: GitLabInstance, force: Bool = false) async {
        if !force, let list = todoLists[instance.baseURL], now.timeIntervalSince(list.loaded) < Self.todoTTL { return }
        do {
            let result = try await provider.todos(instance)
            todoLists[instance.baseURL] = TodoList(todos: result.todos, truncated: result.truncated, loaded: now)
            todoProblems[instance.baseURL] = nil
        } catch {
            todoProblems[instance.baseURL] = (error as? ForgeError)?.description ?? ExtrasError.message(error)
        }
    }

    /// Every pending to-do across instances with a token, newest first.
    public var allTodos: [(instance: String, todo: GitLabTodo)] {
        todoLists.flatMap { key, list in list.todos.map { (key, $0) } }.sorted { ($0.todo.created ?? .distantPast) > ($1.todo.created ?? .distantPast) }
    }

    /// Marks a to-do done on GitLab (the person's explicit action; needs the instance's write switch).
    public func markDone(_ todo: GitLabTodo, instance baseURL: String) async throws {
        try mergeRequests.requireWrites(baseURL)
        guard let instance = mergeRequests.instances.first(where: { $0.baseURL == baseURL }) else { throw ForgeError.noInstance(baseURL) }
        try await provider.markTodoDone(instance, id: todo.id)
        todoLists[baseURL]?.todos.removeAll { $0.id == todo.id }
    }

    // MARK: Approvals

    /// Reads what the instance reports about the MR's approvals and builds the explanation. Rules and project settings
    /// are asked only where the capability may exist; a 404/403 records them as unavailable for the instance.
    @discardableResult
    public func loadApprovals(_ ref: MergeRequestRef) async -> ApprovalExplanation? {
        do {
            let overview = try await provider.approvalOverview(ref)
            var rules: [ApprovalRuleDetail]?
            if mergeRequests.capabilities(ref.instance).support(.approvalRules).mayTry {
                do {
                    rules = try await provider.approvalRuleDetails(ref)
                    mergeRequests.recordProbe(ref.instance, .approvalRules, true)
                } catch ForgeError.notFound, ForgeError.forbidden {
                    mergeRequests.recordProbe(ref.instance, .approvalRules, false)
                }
            }
            var settings: ApprovalSettings?
            let project = try mergeRequests.forgeProject(ref)
            if mergeRequests.capabilities(ref.instance).support(.approvalSettings).mayTry {
                do {
                    settings = try await provider.approvalSettings(project)
                    mergeRequests.recordProbe(ref.instance, .approvalSettings, true)
                } catch ForgeError.notFound, ForgeError.forbidden {
                    mergeRequests.recordProbe(ref.instance, .approvalSettings, false)
                }
            }
            let explanation = ApprovalExplanation.make(
                overview: overview, rules: rules, rulesSupport: mergeRequests.capabilities(ref.instance).support(.approvalRules), settings: settings,
                mergeStatus: mergeRequests.snapshots[ref.url]?.mergeStatus)
            approvalExplanations[ref.url] = explanation
            return explanation
        } catch {
            return approvalExplanations[ref.url]
        }
    }

    // MARK: Dependencies

    /// GitLab's dependencies where offered (Premium/Ultimate); otherwise the open MRs whose branches meet this one's.
    @discardableResult
    public func loadDependencies(_ ref: MergeRequestRef) async -> MergeRequestDependencies? {
        var cached = mergeRequests.snapshots[ref.url]
        if cached == nil { cached = await mergeRequests.refresh(ref) }
        guard let snapshot = cached, let project = try? mergeRequests.forgeProject(ref) else { return nil }
        if mergeRequests.capabilities(ref.instance).support(.mergeRequestDependencies).mayTry {
            do {
                let blockedBy = try await provider.dependencies(ref, blockees: false)
                mergeRequests.recordProbe(ref.instance, .mergeRequestDependencies, true)
                var blocks: [RelatedMergeRequest] = []
                var unknown = false
                do { blocks = try await provider.dependencies(ref, blockees: true) } catch { unknown = true }
                let result = MergeRequestDependencies(source: .gitLab, blockedBy: blockedBy, blocks: blocks, blocksUnknown: unknown)
                dependencies[ref.url] = result
                return result
            } catch ForgeError.notFound, ForgeError.forbidden {
                mergeRequests.recordProbe(ref.instance, .mergeRequestDependencies, false)
            } catch {
                return dependencies[ref.url]
            }
        }
        do {
            let below = try await provider.branchMergeRequests(project, sourceBranch: snapshot.targetBranch)
            let above = try await provider.branchMergeRequests(project, targetBranch: snapshot.sourceBranch)
            let why: String =
                if case .unavailable(let reason) = mergeRequests.capabilities(ref.instance).support(.mergeRequestDependencies) { reason } else {
                    "Merge request dependencies are not offered by this instance."
                }
            let result = MergeRequestDependencies(
                source: .branches(why + " Showing branch relationships instead (GitLab does not enforce them)."),
                blockedBy: below.filter { $0.iid != ref.iid }, blocks: above.filter { $0.iid != ref.iid })
            dependencies[ref.url] = result
            return result
        } catch {
            return dependencies[ref.url]
        }
    }

    // MARK: Code Owners

    /// Reads the repository's CODEOWNERS (GitLab's locations, first found, at the MR's target branch, else HEAD)
    /// through git and matches the MR's changed files. No host runtime runs; GitLab's `approval_state` stays
    /// authoritative.
    @discardableResult
    public func loadCodeOwners(_ ref: MergeRequestRef, directory: String, paths: [String]) async -> CodeOwnersSummary? {
        let repository = GitRepository(directory: directory)
        let target = mergeRequests.snapshots[ref.url]?.targetBranch
        let revisions = (target.map { ["origin/\($0)", $0] } ?? []) + ["HEAD"]
        for revision in revisions {
            guard (try? await repository.resolves(revision)) == true else { continue }
            for location in CodeOwnersFile.locations {
                guard let data = try? await repository.content(at: revision, path: location, limit: 512 << 10) else { continue }
                let file = CodeOwnersFile(String(decoding: data, as: UTF8.self), path: location)
                let summary = await Self.match(file, paths: paths, revision: revision)
                codeOwners[ref.url] = summary
                codeOwnersNotes[ref.url] = nil
                return summary
            }
            codeOwners[ref.url] = nil
            codeOwnersNotes[ref.url] = "No CODEOWNERS file at \(revision) (looked in \(CodeOwnersFile.locations.joined(separator: ", ")))."
            return nil
        }
        codeOwnersNotes[ref.url] = "The thread's folder is not a git checkout of this project, so CODEOWNERS could not be read."
        return nil
    }

    @concurrent
    static func match(_ file: CodeOwnersFile, paths: [String], revision: String) async -> CodeOwnersSummary {
        CodeOwnersSummary(file: file, paths: paths, revision: revision)
    }
}

extension LinkedIssue {
    public static func decode(fromMetadata raw: RawJSON?) -> [LinkedIssue] {
        guard let raw, let data = raw.text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object[metadataKey], let listData = try? JSONSerialization.data(withJSONObject: list)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([LinkedIssue].self, from: listData)) ?? []
    }

    /// The session metadata with the list replaced (other keys kept).
    public static func encode(_ links: [LinkedIssue], intoMetadata raw: RawJSON?) -> [String: Any] {
        var object: [String: Any] = [:]
        if let raw, let data = raw.text.data(using: .utf8), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        if let data = try? encoder.encode(links), let list = try? JSONSerialization.jsonObject(with: data) { object[metadataKey] = list }
        return object
    }
}
