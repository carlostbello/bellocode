import AppKit
import BelloCore
import Engine
import Observation

/// The thread's checkout as the create form needs it.
public struct CheckoutState: Equatable, Sendable {
    public var branch: String?
    public var remote: String?
    public var upstream: String?
    public var ahead: Int

    public init(branch: String?, remote: String?, upstream: String?, ahead: Int) {
        self.branch = branch
        self.remote = remote
        self.upstream = upstream
        self.ahead = ahead
    }

    /// The branch is on the remote with nothing left to push.
    public var isPushed: Bool { upstream != nil && ahead == 0 }
}

/// What the app gives the create form for one thread: its checkout (git, the person's own transport), Push through
/// the existing git service, the commit subjects since the target, and the thread's model for a proposal.
@MainActor
public struct CreateMergeRequestContext {
    public var sessionID: SessionID
    public var directory: String
    public var checkout: () async -> CheckoutState?
    public var push: () async throws -> Void
    /// Commit subjects on the branch since `target` (newest last).
    public var commits: (_ target: String) async -> [String]
    /// The thread's model (opencode `POST /api/session/{id}/generate`); nil when unavailable.
    public var generate: ((String) async throws -> String)?

    public init(
        sessionID: SessionID, directory: String, checkout: @escaping () async -> CheckoutState?, push: @escaping () async throws -> Void,
        commits: @escaping (String) async -> [String], generate: ((String) async throws -> String)?
    ) {
        self.sessionID = sessionID
        self.directory = directory
        self.checkout = checkout
        self.push = push
        self.commits = commits
        self.generate = generate
    }
}

/// The inline (sheet-free) "New Merge Request" form: generated, editable title and description, target branch,
/// draft, optional assignees and reviewers, and a preview of exactly what will be POSTed.
@MainActor
@Observable
public final class CreateMergeRequestModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case creating
        case failed(String)
    }

    public let service: MergeRequestService
    public let context: CreateMergeRequestContext
    public private(set) var phase: Phase = .loading
    public private(set) var project: ForgeProject?
    public private(set) var checkout: CheckoutState?
    public private(set) var branchOptions: [String] = []
    public var title = "" { didSet { if title != generatedTitle { edited = true } } }
    public var description = "" { didSet { if description != generatedDescription { edited = true } } }
    public var target = ""
    public var draft = false
    public var removeSourceBranch = true
    public var assigneeQuery = ""
    public var reviewerQuery = ""
    public private(set) var assignees: [GitLabUserRef] = []
    public private(set) var reviewers: [GitLabUserRef] = []
    /// "Proposed by the thread's model" / "From the commit log" (the person edits either).
    public private(set) var proposalSource = ""
    public private(set) var generating = false
    public private(set) var pushing = false
    public private(set) var problem: String?
    @ObservationIgnored private var generatedTitle = ""
    @ObservationIgnored private var generatedDescription = ""
    @ObservationIgnored private var edited = false
    @ObservationIgnored public var onCreated: (MergeRequestRef) -> Void = { _ in }
    @ObservationIgnored public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    public init(service: MergeRequestService, context: CreateMergeRequestContext) {
        self.service = service
        self.context = context
    }

    public var sourceBranch: String { checkout?.branch ?? "" }

    public var mergeDraft: MergeRequestDraft {
        MergeRequestDraft(
            sourceBranch: sourceBranch, targetBranch: target, title: title, description: description, draft: draft,
            assigneeIDs: assignees.map(\.id), reviewerIDs: reviewers.map(\.id), removeSourceBranch: removeSourceBranch)
    }

    /// "POST https://host/gitlab/api/v4/projects/group%2Fproj/merge_requests".
    public var endpointText: String {
        guard let project else { return "" }
        let path = project.projectPath.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? project.projectPath
        return "POST \(project.instance.apiBase)/projects/\(path)/merge_requests"
    }

    /// Why Create is unavailable (nil when it can be sent).
    public var blocker: String? {
        if phase == .creating { return "Creating…" }
        if project == nil { return problem ?? "Checking the checkout…" }
        if let checkout, !checkout.isPushed {
            return checkout.upstream == nil ? "Push the branch first: it is not on the remote yet." : "Push the branch first: \(checkout.ahead) commit(s) are not on the remote."
        }
        if let problem = mergeDraft.problems.first { return problem }
        do { try service.requireWrites(project!.instance.baseURL) } catch { return ExtrasError.message(error) }
        return nil
    }

    public func prepare() async {
        phase = .loading
        problem = nil
        checkout = await context.checkout()
        guard let checkout, let branch = checkout.branch, let remote = checkout.remote else {
            fail("This thread's folder has no branch or no origin remote.")
            return
        }
        guard let project = ForgeProject.resolve(remote: remote, instances: service.instances) else {
            fail("The origin remote (\(remote)) is not on a GitLab instance added in Settings ▸ GitLab.")
            return
        }
        self.project = project
        do {
            let info = try await service.projectInfo(project)
            target = target.isEmpty ? (info.defaultBranch ?? "main") : target
            branchOptions = ((try? await service.branches(project, search: "")) ?? []).filter { $0 != branch }
            if !branchOptions.contains(target) { branchOptions.insert(target, at: 0) }
        } catch {
            target = target.isEmpty ? "main" : target
            problem = "GitLab could not be asked for the project's branches: \((error as? ForgeError)?.description ?? error.localizedDescription)"
        }
        phase = .ready
        await propose(branch: branch)
    }

    private func fail(_ text: String) {
        problem = text
        phase = .failed(text)
    }

    /// The template at once, then the thread's model's proposal if it answers before the person edits.
    public func propose(branch: String) async {
        let commits = await context.commits(target)
        let template = MergeRequestTemplate.make(branch: branch, commits: commits)
        apply(template, source: "From the branch's commits")
        guard let generate = context.generate else { return }
        generating = true
        defer { generating = false }
        do {
            let answer = try await generate(MergeRequestTemplate.prompt(branch: branch, target: target, commits: commits))
            if !edited, let proposal = MergeRequestTemplate.parse(answer) { apply(proposal, source: "Proposed by the thread's model") }
        } catch {
            proposalSource = "From the branch's commits (the model could not be asked)"
        }
    }

    private func apply(_ proposal: (title: String, description: String), source: String) {
        generatedTitle = proposal.title
        generatedDescription = proposal.description
        title = proposal.title
        description = proposal.description
        edited = false
        proposalSource = source
    }

    public func push() async {
        pushing = true
        defer { pushing = false }
        do {
            try await context.push()
            checkout = await context.checkout()
            problem = nil
        } catch {
            problem = "Push failed: \(error.localizedDescription)"
        }
    }

    /// Adds the first project member matching the query (never a global user search).
    public func addPerson(reviewer: Bool) async {
        guard let project else { return }
        let query = (reviewer ? reviewerQuery : assigneeQuery).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !query.isEmpty else { return }
        do {
            let found = try await service.users(project, search: query)
            guard let user = found.first(where: { $0.username.lowercased() == query.lowercased() }) ?? found.first else {
                problem = "No member of \(project.projectPath) matches “\(query)”."
                return
            }
            if reviewer {
                if !reviewers.contains(user) { reviewers.append(user) }
                reviewerQuery = ""
            } else {
                if !assignees.contains(user) { assignees.append(user) }
                assigneeQuery = ""
            }
            problem = nil
        } catch {
            problem = (error as? ForgeError)?.description ?? error.localizedDescription
        }
    }

    public func remove(_ user: GitLabUserRef, reviewer: Bool) {
        if reviewer { reviewers.removeAll { $0 == user } } else { assignees.removeAll { $0 == user } }
    }

    public func create() async {
        guard blocker == nil, let project else { return }
        phase = .creating
        do {
            let ref = try await service.createMergeRequest(mergeDraft, in: project, for: context.sessionID)
            phase = .ready
            onCreated(ref)
        } catch {
            phase = .ready
            problem = ExtrasError.message(error)
        }
    }

    /// GitLab's own new-MR page for the branch (the fallback).
    public func openInGitLab() {
        guard let project, let url = project.newMergeRequestURL(branch: sourceBranch, target: target.isEmpty ? nil : target) else { return }
        openURL(url)
    }
}
