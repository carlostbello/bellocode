import BelloCore
import Foundation
import Observation

/// One background clone (T3 Code: "the project opens right away while the clone runs in the background: you can write
/// your first prompt, and sending waits until the files are in place").
@MainActor
@Observable
public final class GitCloneJob: Identifiable {
    public enum State: Sendable, Equatable {
        case cloning
        case finished
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let url: String
    public let destination: String
    /// `group/project` for display.
    public let name: String
    public private(set) var state: State = .cloning
    public let started = ContinuousClock.now
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    init(url: String, destination: String, name: String) {
        self.url = url
        self.destination = destination
        self.name = name
    }

    public var isFinished: Bool { state == .finished }

    func finish(_ state: State) {
        self.state = state
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once the clone ended (any outcome); `state` says how. A send waits here.
    public func waitUntilDone() async {
        if state != .cloning { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func cancel() { task?.cancel() }
}

/// Clone from GitLab, publish to GitLab, and new projects from scratch (docs/features/git-parity.md rows 19, 20, 22).
/// git runs confined on the host; HTTPS authentication goes through the app's credential helper.
@MainActor
@Observable
public final class GitProjectService {
    public private(set) var clones: [GitCloneJob] = []
    @ObservationIgnored let git: GitService
    @ObservationIgnored let provider: @MainActor () -> GitLabProvider?
    @ObservationIgnored let addProject: @MainActor (String) async -> Void

    init(git: GitService, provider: @escaping @MainActor () -> GitLabProvider?, addProject: @escaping @MainActor (String) async -> Void) {
        self.git = git
        self.provider = provider
        self.addProject = addProject
    }

    /// `~/BelloCode/<host>/<group>/<project>` (ghq-style layout; editable before cloning).
    public static func defaultDestination(for url: String, home: String = NSHomeDirectory()) -> String? {
        guard let parsed = GitRemoteURL(url) else { return nil }
        return (home as NSString).appendingPathComponent("BelloCode/\(parsed.host)/\(parsed.projectPath)")
    }

    public func job(for directory: String) -> GitCloneJob? { clones.last { $0.destination == directory } }

    public func searchProjects(_ instance: GitLabInstance, search: String) async throws -> [GitLabProjectSummary] {
        guard let provider = provider() else { return [] }
        return try await provider.searchProjects(instance, search: search)
    }

    /// Starts cloning `url` into `destination` (which must not exist or be empty) and returns at once. The project is
    /// added to the sidebar at once (T3 Code: it opens right away); `job(for:)` lets the composer's send wait for the
    /// files. A failed clone leaves the project listed with the job's error and Retry.
    @discardableResult
    public func clone(url: String, into destination: String) throws -> GitCloneJob {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination), !((try? manager.contentsOfDirectory(atPath: destination)) ?? []).isEmpty {
            throw GitError.failed(command: "clone", status: 1, message: "The folder \((destination as NSString).abbreviatingWithTildeInPath) already exists and is not empty.")
        }
        let parent = (destination as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let job = GitCloneJob(url: url, destination: destination, name: GitRemoteURL(url)?.projectPath ?? (destination as NSString).lastPathComponent)
        clones.append(job)
        if clones.count > 16 { clones.removeFirst(clones.count - 16) }
        let runner = git.runner
        try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let add = addProject
        Task { await add(destination) }
        job.task = Task { [weak self, weak job] in
            let result: GitCloneJob.State
            do {
                _ = try await runner.run(["clone", "--quiet", "--", url, destination], in: parent, timeout: .seconds(1_800), writableRoots: [parent])
                result = .finished
            } catch is CancellationError {
                Self.empty(destination)
                result = .cancelled
            } catch {
                Self.empty(destination)
                result = .failed((error as? GitError)?.userMessage ?? "The clone failed.")
            }
            if result == .finished { self?.git.refreshAll(under: destination) }
            job?.finish(result)
        }
        return job
    }

    /// Removes what a failed clone left inside `destination`, keeping the (listed) folder itself.
    nonisolated static func empty(_ destination: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? [] {
            try? FileManager.default.removeItem(atPath: (destination as NSString).appendingPathComponent(name))
        }
    }

    /// Starts the same clone again after a failure or cancel.
    @discardableResult
    public func retry(_ job: GitCloneJob) throws -> GitCloneJob {
        clones.removeAll { $0 === job }
        return try clone(url: job.url, into: job.destination)
    }

    /// Creates a private project on `instance`, adds it as `origin` (HTTPS) and pushes the current branch when there
    /// are commits. Refuses when the repository already has `origin`.
    public func publish(directory: String, instance: GitLabInstance, name: String, path: String, namespaceID: Int?) async throws -> GitLabProjectSummary {
        guard let provider = provider() else { throw ForgeError.noInstance(instance.baseURL) }
        let repository = GitRepository(directory: directory, runner: git.runner)
        if try await repository.remoteURL() != nil {
            throw GitError.failed(command: "publish", status: 1, message: "This repository already has an origin remote.")
        }
        let created = try await provider.createProject(instance, name: name, path: path, namespaceID: namespaceID)
        try await repository.addRemote("origin", url: created.httpURL)
        let status = try await repository.status(limit: 1)
        if status.head != nil, let branch = status.branch {
            try await repository.push(branch: branch, setUpstream: true)
        }
        git.refreshAll(under: directory)
        return created
    }

    /// A new folder `parent/<slug>` with `git init`, a README and a first commit (when an identity is configured),
    /// added as a project. Returns the folder.
    public func createProject(named name: String, in parent: String) async throws -> String {
        let slug = WorktreeService.slug(name, prefix: "")
        let directory = (parent as NSString).appendingPathComponent(slug)
        if FileManager.default.fileExists(atPath: directory) {
            throw GitError.failed(command: "init", status: 1, message: "A folder named \(slug) already exists there.")
        }
        var runner = git.runner
        runner.writableRoots.append(parent)
        _ = try await GitRepository.initialise(at: directory, readme: "# \(name)\n", runner: runner)
        await addProject(directory)
        return directory
    }
}
