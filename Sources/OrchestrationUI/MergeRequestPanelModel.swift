import AppKit
import BelloCore
import Engine
import Observation

/// View state of the "Merge Requests" tab (docs/features/gitlab.md): which MR is expanded, the open job log, triage
/// excerpts, the create form and messages. GitLab state itself lives in `MergeRequestService` (cached first).
@MainActor
@Observable
public final class MergeRequestPanelModel {
    public enum LogState: Equatable {
        case idle
        case loading
        case loaded(ParsedJobLog, headOmitted: Bool, totalBytes: Int?)
        case failed(String)
    }

    public struct OpenLog: Equatable {
        public var ref: MergeRequestRef
        public var job: PipelineJob
    }

    public let service: MergeRequestService
    public private(set) var threadID: SessionID?
    public var linkText = ""
    public private(set) var message: String?
    public private(set) var notice: String?
    public private(set) var lastUnlinked: (thread: SessionID, link: LinkedMergeRequest)?
    /// The expanded MR (its URL); nil shows the first.
    public var expanded: String?
    public var failuresOnly = false
    public private(set) var openLog: OpenLog?
    public private(set) var log: LogState = .idle
    /// Triage excerpts by job ID (sanitised, bounded).
    public private(set) var excerpts: [Int: JobLogExcerpt] = [:]
    public private(set) var excerptLoading: Set<Int> = []
    public private(set) var busyActions: Set<String> = []
    /// The create-merge-request form (nil when closed).
    public var create: CreateMergeRequestModel?
    /// Opens a URL: in the default browser, or the built-in one (`builtIn`).
    @ObservationIgnored public var openURL: (URL, Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }
    @ObservationIgnored public var openSettings: () -> Void = {}
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Inserts text into the thread's composer (the person sends it). Nil when no composer is shown.
    @ObservationIgnored public var insertIntoComposer: ((String) -> Void)?
    /// Asks the person to confirm something that cannot be undone (title, detail, confirm button). True to go on.
    @ObservationIgnored public var confirm: (String, String, String) -> Bool = { _, _, _ in false }
    /// Builds the create form's context for the thread (checkout, commits, model generation); set by the app.
    @ObservationIgnored public var makeCreateContext: ((SessionID) -> CreateMergeRequestContext?)?

    public init(service: MergeRequestService) {
        self.service = service
    }

    public func display(_ id: SessionID?) {
        guard id != threadID else { return }
        threadID = id
        message = nil
        notice = nil
        expanded = nil
        closeLog()
        create = nil
        if let id {
            Task {
                await service.refresh(thread: id)
                for link in service.links(for: id) {
                    await service.loadWakeLog(id, link.ref.url)
                    await service.loadApprovalRules(link.ref)
                }
            }
        }
    }

    public var links: [LinkedMergeRequest] { threadID.map(service.links(for:)) ?? [] }

    public var expandedURL: String? { expanded ?? links.first?.ref.url }

    public func toggle(_ link: LinkedMergeRequest) {
        expanded = expandedURL == link.ref.url ? "" : link.ref.url
        if expanded == link.ref.url, let threadID {
            Task {
                await service.loadWakeLog(threadID, link.ref.url)
                await service.loadApprovalRules(link.ref)
            }
        }
    }

    public func link() async {
        guard let threadID else { return }
        do {
            let ref = try await service.resolve(linkText, for: threadID)
            try await service.link([ref], to: threadID, source: .user)
            linkText = ""
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func unlink(_ link: LinkedMergeRequest) async {
        guard let threadID else { return }
        do {
            try await service.unlink([link.ref], from: threadID)
            lastUnlinked = (threadID, link)
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func undoUnlink() async {
        guard let last = lastUnlinked else { return }
        lastUnlinked = nil
        _ = try? await service.link([last.link.ref], to: last.thread, source: last.link.source, watch: last.link.watching)
    }

    /// "Babysit this MR" / "Stop Babysitting" (the person's own choice: no approval card).
    public func setWatching(_ link: LinkedMergeRequest, _ watching: Bool) async {
        guard let threadID else { return }
        do {
            try await service.setWatching(link.ref, for: threadID, watching)
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func refresh() async {
        for link in links { await service.refresh(link.ref) }
    }

    // MARK: Job log

    public func showLog(_ ref: MergeRequestRef, _ job: PipelineJob) {
        openLog = OpenLog(ref: ref, job: job)
        log = .loading
        Task { await loadLog() }
    }

    public func closeLog() {
        openLog = nil
        log = .idle
    }

    public func loadLog() async {
        guard let open = openLog else { return }
        log = .loading
        switch await service.jobLog(open.ref, jobID: open.job.id) {
        case .success(let chunk):
            let parsed = await Self.parse(chunk.text)
            guard openLog == open else { return }
            log = .loaded(parsed, headOmitted: chunk.headOmitted, totalBytes: chunk.totalBytes)
        case .failure(let error):
            guard openLog == open else { return }
            log = .failed(error.description)
        }
    }

    @concurrent
    static func parse(_ text: String) async -> ParsedJobLog { ParsedJobLog(text) }

    // MARK: Triage

    public func loadExcerpt(_ ref: MergeRequestRef, _ job: PipelineJob) async {
        guard excerpts[job.id] == nil, !excerptLoading.contains(job.id) else { return }
        excerptLoading.insert(job.id)
        defer { excerptLoading.remove(job.id) }
        switch await service.jobLog(ref, jobID: job.id, maxBytes: 64 << 10) {
        case .success(let chunk):
            excerpts[job.id] = await Self.excerpt(chunk.text, headOmitted: chunk.headOmitted, known: service.knownSecrets(ref.instance))
        case .failure(let error):
            message = "The log of \(job.name) could not be read: \(error.description)"
        }
    }

    @concurrent
    static func excerpt(_ text: String, headOmitted: Bool, known: [String]) async -> JobLogExcerpt {
        JobLogExcerpt(log: text, headOmitted: headOmitted, known: known)
    }

    /// The composer text for "Send to Agent": a request plus the excerpt, quoted and labelled untrusted.
    public static func agentText(_ snapshot: MergeRequestSnapshot, _ job: PipelineJob, _ excerpt: JobLogExcerpt) -> String {
        let pipeline = snapshot.pipeline.map { "pipeline #\($0.id)" } ?? "the pipeline"
        let sha = snapshot.pipeline?.sha ?? snapshot.sha
        return UntrustedText.composerQuote(
            intro: "The GitLab job “\(job.name)” (#\(job.id), stage \(job.stage.isEmpty ? "–" : job.stage)) failed in \(pipeline) of \(snapshot.ref)\(sha.isEmpty ? "" : " at \(sha.prefix(12))"). Find out why and fix it. The log excerpt below is output from GitLab, quoted as data:",
            label: "log excerpt of job \(job.name), \(snapshot.ref)", body: excerpt.text)
    }

    public func sendToAgent(_ ref: MergeRequestRef, _ job: PipelineJob) async {
        await loadExcerpt(ref, job)
        guard let excerpt = excerpts[job.id], let snapshot = service.snapshots[ref.url] else { return }
        guard let insert = insertIntoComposer else {
            message = "Open the thread's composer to send the excerpt."
            return
        }
        insert(Self.agentText(snapshot, job, excerpt))
        notice = "The excerpt of \(job.name) is in the composer: review it and send."
    }

    // MARK: Actions (the person's own)

    public func retry(_ ref: MergeRequestRef, _ job: PipelineJob) async {
        await run("retry-\(job.id)") {
            _ = try await self.service.retryJob(ref, jobID: job.id)
            self.notice = "Retried \(job.name)."
        }
    }

    /// Manual jobs can deploy: always confirmed.
    public func play(_ ref: MergeRequestRef, _ job: PipelineJob) async {
        guard confirm("Run the manual job “\(job.name)”?", "It runs in \(ref) (stage \(job.stage)) and may deploy. It cannot be undone from BelloCode.", "Run Job") else { return }
        await run("play-\(job.id)") {
            _ = try await self.service.playJob(ref, jobID: job.id)
            self.notice = "Started \(job.name)."
        }
    }

    public func approve(_ snapshot: MergeRequestSnapshot) async {
        await run("approve-\(snapshot.ref.url)") {
            try await self.service.approve(snapshot.ref, sha: snapshot.sha)
            self.notice = "Approved \(snapshot.ref) at \(snapshot.sha.prefix(12))."
        }
    }

    public func merge(_ snapshot: MergeRequestSnapshot) async {
        guard confirm(
            "Merge \(snapshot.ref)?", "“\(snapshot.title)”: \(snapshot.sourceBranch) → \(snapshot.targetBranch) at \(snapshot.sha.prefix(12)). GitLab applies its merge checks. This cannot be undone.",
            "Merge")
        else { return }
        await run("merge-\(snapshot.ref.url)") {
            try await self.service.merge(snapshot.ref, sha: snapshot.sha)
            self.notice = "Merged \(snapshot.ref)."
        }
    }

    public func isBusy(_ action: String) -> Bool { busyActions.contains(action) }

    private func run(_ action: String, _ body: @escaping () async throws -> Void) async {
        guard !busyActions.contains(action) else { return }
        busyActions.insert(action)
        defer { busyActions.remove(action) }
        do {
            try await body()
            message = nil
        } catch {
            message = ExtrasError.message(error)
            notice = nil
        }
    }

    // MARK: Create

    public func openCreate() {
        guard let threadID, let context = makeCreateContext?(threadID) else {
            message = "Select a thread whose folder is a git checkout with an origin on a configured GitLab instance."
            return
        }
        let model = CreateMergeRequestModel(service: service, context: context)
        model.onCreated = { [weak self] ref in
            self?.create = nil
            self?.expanded = ref.url
            self?.notice = "Created \(ref) and linked it to this thread."
        }
        create = model
        Task { await model.prepare() }
    }
}
