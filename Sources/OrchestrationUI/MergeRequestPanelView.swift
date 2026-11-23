import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// The "Merge Requests" right-panel tab (docs/features/gitlab.md). Cached first: a linked MR shows its last snapshot
/// with its time at once, marked stale or offline when GitLab cannot be read; never a blank pane. Each MR expands to
/// its overview, approvals, pipeline (stages, jobs, failure triage), discussions (read-only) and babysit state; a job's
/// log opens in place (virtualised, bounded, ANSI colours). The create form is inline.
public struct MergeRequestPanelView: View {
    let model: MergeRequestPanelModel

    public init(model: MergeRequestPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let open = model.openLog {
                JobLogPane(model: model, open: open)
            } else {
                if model.work != nil { sectionPicker }
                switch model.section {
                case .mergeRequests:
                    header
                    notices
                    SwiftUI.Color.ds.border.frame(height: 1)
                    content
                case .issues:
                    notices
                    IssuesView(model: model)
                case .todos:
                    notices
                    TodosView(model: model)
                }
            }
        }
        .buttonStyle(DSButtonStyle(.outline, size: .small))
        .toggleStyle(DSToggleStyle(.checkbox))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SwiftUI.Color.ds.canvas)
        .transaction { $0.animation = nil }
    }

    /// Merge Requests · Issues · To-dos (GitLab 2). Keyboard: the GitLab menu's Show Issues / Show To-dos.
    private var sectionPicker: some View {
        HStack {
            DSSegmentedPicker(options: MergeRequestPanelModel.Section.allCases.map { ($0, $0.title) }, selection: Bindable(model).section)
                .accessibilityLabel("GitLab section")
            Spacer()
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.top, DS.Space.s8)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s6) {
            Text("Merge Requests").font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text)
            Spacer()
            Button {
                model.openCreate()
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(DSButtonStyle(.ghost, size: .small))
            .help("Create a merge request from this thread's branch")
            .disabled(model.threadID == nil || model.create != nil)
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
            .help("Check GitLab now")
            .disabled(model.links.isEmpty)
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
    }

    @ViewBuilder
    private var notices: some View {
        let service = model.service
        let warnings = service.instances.compactMap { instance in service.tokenWarning(instance.baseURL).map { (instance, $0) } }
        if service.instances.isEmpty || !service.instanceProblems.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                if service.instances.isEmpty {
                    Label("Connect GitLab: add your instance and an access token in Settings ▸ GitLab.", systemImage: "link.badge.plus")
                        .foregroundStyle(SwiftUI.Color.ds.text2)
                }
                ForEach(service.instanceProblems.sorted(by: { $0.key < $1.key }), id: \.key) { _, problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.warningText)
                }
                ForEach(warnings, id: \.0.baseURL) { instance, warning in
                    Label("\(instance.host): \(warning.text)", systemImage: warning.level >= 2 ? "exclamationmark.octagon" : "clock.badge.exclamationmark")
                        .foregroundStyle(warning.level >= 1 ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.text2)
                }
                Button("Open GitLab Settings…") { model.openSettings() }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            }
            .font(.ds(.meta))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.s12)
            .padding(.bottom, DS.Space.s8)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.threadID == nil {
            Text("Select a thread to see its merge requests.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s10) {
                    if let create = model.create { CreateMergeRequestView(model: create, cancel: { model.create = nil }) }
                    if model.links.isEmpty && model.create == nil {
                        Text("No merge requests linked to this thread. An open MR for this thread's branch, or one a git push here prints, is linked automatically; agents link them with link_merge_requests. New creates one from this branch.")
                            .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.links) { link in MergeRequestCard(model: model, link: link, expanded: model.expandedURL == link.ref.url) }
                    linkField
                    if let last = model.lastUnlinked {
                        HStack {
                            Text("Unlinked \(last.link.ref.description).").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text2)
                            Button("Undo") { Task { await model.undoUnlink() } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        }
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.successText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.s12)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                model.scrollTarget = nil
            }
            }
        }
    }

    private var linkField: some View {
        HStack(spacing: DS.Space.s6) {
            TextField("Link an MR: URL or !123", text: Bindable(model).linkText)
                .textFieldStyle(DSTextFieldStyle())
                .onSubmit { Task { await model.link() } }
                .accessibilityLabel("Merge request to link: URL or !number")
            Button("Link") { Task { await model.link() } }
                .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// Colours for GitLab states (always next to a glyph and a word).
enum GitLabTone {
    static func pipeline(_ summary: PipelineSummary) -> SwiftUI.Color {
        switch summary {
        case .passed: SwiftUI.Color.ds.successText
        case .failed: SwiftUI.Color.ds.dangerText
        case .running, .manual: SwiftUI.Color.ds.infoText
        case .none, .canceled: SwiftUI.Color.ds.text3
        }
    }

    static func job(_ job: PipelineJob) -> SwiftUI.Color {
        switch job.status {
        case "success": SwiftUI.Color.ds.successText
        case "failed": job.allowFailure == true ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.dangerText
        case "running": SwiftUI.Color.ds.infoText
        case "manual": SwiftUI.Color.ds.warningText
        default: SwiftUI.Color.ds.text3
        }
    }

    static func state(_ snapshot: MergeRequestSnapshot?) -> DS.Tone {
        switch snapshot?.state {
        case .opened: snapshot?.draft == true ? .neutral : .success
        case .merged: .info
        case .closed, .locked: .danger
        case nil: .neutral
        }
    }
}

struct MergeRequestCard: View {
    let model: MergeRequestPanelModel
    let link: LinkedMergeRequest
    let expanded: Bool

    var body: some View {
        let snapshot = model.service.snapshots[link.ref.url]
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            Button {
                model.toggle(link)
            } label: {
                summary(snapshot)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MergeRequestText.accessibility(link, snapshot))
            .accessibilityHint(expanded ? "Collapse" : "Show details")
            freshness(snapshot)
            if expanded {
                if let snapshot {
                    OverviewSection(snapshot: snapshot, link: link)
                    ApprovalsSection(model: model, snapshot: snapshot).id("approvals")
                    PipelineSection(model: model, snapshot: snapshot).id("pipeline")
                    DiscussionsSection(snapshot: snapshot).id("discussions")
                    if model.work != nil { DependenciesSection(model: model, snapshot: snapshot).id("dependencies") }
                } else if model.service.problems[link.ref.url] == nil {
                    Text("Checking GitLab…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                }
                BabysitSection(model: model, link: link).id("babysit")
                actions(snapshot)
            }
        }
        .padding(DS.Space.s10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.raised))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func summary(_ snapshot: MergeRequestSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color.ds.text4).frame(width: 10).accessibilityHidden(true)
                Text("!\(link.ref.iid)").font(.ds(.bodyEmph)).monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                Text(snapshot?.title ?? link.ref.description).font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Space.s6) {
                DSPillView(snapshot?.stateLabel ?? "Linked", tone: GitLabTone.state(snapshot), symbolName: snapshot?.state.symbolName)
                if let snapshot, snapshot.state == .opened {
                    let pipeline = snapshot.pipelineSummary
                    Label(pipeline.text, systemImage: pipeline.symbolName).foregroundStyle(GitLabTone.pipeline(pipeline))
                    Text(MergeRequestText.approvalCount(snapshot)).foregroundStyle(SwiftUI.Color.ds.text2)
                }
                if link.watching { Label("Babysitting", systemImage: "eye").foregroundStyle(SwiftUI.Color.ds.infoText) }
            }
            .font(.ds(.meta))
            .padding(.leading, 16)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func freshness(_ snapshot: MergeRequestSnapshot?) -> some View {
        let service = model.service
        if let kind = service.failureKinds[link.ref.url] {
            Label(
                snapshot.map { "\(kind.label) · showing data from \(ExtrasTime.relative($0.fetched, now: model.now()))" } ?? kind.label,
                systemImage: kind == .offline ? "wifi.slash" : "exclamationmark.triangle"
            )
            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText).padding(.leading, 16)
            .help(service.problems[link.ref.url] ?? "")
            if snapshot == nil, let problem = service.problems[link.ref.url] {
                Text(problem).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true).padding(.leading, 16)
            }
        } else if let snapshot, expanded {
            Text("Updated \(ExtrasTime.relative(snapshot.fetched, now: model.now())) · \(link.ref.projectPath) · \(MergeRequestText.source(link.source))")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.middle).padding(.leading, 16)
        }
    }

    private func actions(_ snapshot: MergeRequestSnapshot?) -> some View {
        HStack(spacing: DS.Space.s6) {
            if model.openReview != nil {
                let drafts = model.draftCount(link.ref)
                Button(drafts > 0 ? "Review Diff (\(drafts) draft\(drafts == 1 ? "" : "s"))" : "Review Diff") { model.review(link.ref) }
                    .buttonStyle(DSButtonStyle(.primary, size: .small))
                    .help("Review the merge request's diff with its threads inline (GitLab ▸ Review Merge Request Diff)")
            }
            Button("Open in GitLab") { if let url = URL(string: snapshot?.webURL ?? link.ref.url) { model.openURL(url, false) } }
                .help("Open on GitLab in your default browser")
            Button("Open in BelloCode") { if let url = URL(string: snapshot?.webURL ?? link.ref.url) { model.openURL(url, true) } }
                .help("Open in the built-in browser")
            Spacer()
            Button("Unlink") { Task { await model.unlink(link) } }.buttonStyle(DSButtonStyle(.ghost, size: .small)).help("Unlink from this thread (Undo is offered)")
        }
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title).font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text3)
            Spacer()
            if let trailing { Text(trailing).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
        }
        .padding(.top, DS.Space.s4)
    }
}

struct OverviewSection: View {
    let snapshot: MergeRequestSnapshot
    let link: LinkedMergeRequest

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            SectionTitle(title: "Overview")
            row("Branches", "\(snapshot.sourceBranch) → \(snapshot.targetBranch)")
            row("Author", "@\(snapshot.author)")
            if !snapshot.sha.isEmpty { row("Head", String(snapshot.sha.prefix(12))) }
            if let status = snapshot.mergeStatus { row("Merge status", status.replacingOccurrences(of: "_", with: " ")) }
            if let labels = snapshot.labels, !labels.isEmpty { row("Labels", labels.joined(separator: ", ")) }
            row("Assignees", (snapshot.assignees ?? []).isEmpty ? "None" : snapshot.assignees!.map { "@\($0)" }.joined(separator: ", "))
            row("Reviewers", snapshot.reviewers.map { $0.isEmpty ? "None" : $0.map { "@\($0)" }.joined(separator: ", ") } ?? "Not reported by this GitLab version")
            if let updated = snapshot.updatedAt { row("Updated", updated.formatted(date: .abbreviated, time: .shortened)) }
            if let note = snapshot.truncationNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
            Text(label).foregroundStyle(SwiftUI.Color.ds.text3).frame(width: 96, alignment: .leading)
            Text(value).foregroundStyle(SwiftUI.Color.ds.text).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.ds(.meta))
        .accessibilityElement(children: .combine)
    }
}

struct ApprovalsSection: View {
    let model: MergeRequestPanelModel
    let snapshot: MergeRequestSnapshot

    var body: some View {
        let service = model.service
        let rules = service.approvalRules[snapshot.ref.url]
        let settings = service.settings(for: snapshot.ref.instance)
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            SectionTitle(title: "Approvals", trailing: MergeRequestText.approvalCount(snapshot))
            Label(snapshot.approvals.label, systemImage: snapshot.approvals.approved ? "checkmark.seal" : "seal")
                .foregroundStyle(snapshot.approvals.approved ? SwiftUI.Color.ds.successText : SwiftUI.Color.ds.text2)
            if let explanation = model.work?.approvalExplanations[snapshot.ref.url] {
                ApprovalExplanationView(explanation: explanation)
            } else if let rules, !rules.isEmpty {
                ForEach(rules) { rule in
                    HStack(spacing: DS.Space.s6) {
                        Text(rule.approved ? "✓" : "○").foregroundStyle(rule.approved ? SwiftUI.Color.ds.successText : SwiftUI.Color.ds.text3)
                        Text(rule.isCodeOwner ? "Code Owners\(rule.section.map { " · \($0)" } ?? "")" : rule.name).foregroundStyle(SwiftUI.Color.ds.text)
                        Text("\(rule.approvedBy.count) of \(rule.required)").foregroundStyle(SwiftUI.Color.ds.text3)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let work = model.work { CodeOwnersView(summary: work.codeOwners[snapshot.ref.url], note: work.codeOwnersNotes[snapshot.ref.url]) }
            if settings.approveAndMergeEnabled && snapshot.state == .opened {
                HStack(spacing: DS.Space.s6) {
                    Button("Approve at \(snapshot.sha.prefix(8))") { Task { await model.approve(snapshot) } }
                        .disabled(model.isBusy("approve-\(snapshot.ref.url)"))
                        .help("Approve this exact head commit (GitLab refuses if it changed)")
                    Button("Merge…") { Task { await model.merge(snapshot) } }
                        .disabled(model.isBusy("merge-\(snapshot.ref.url)"))
                        .help("Merge at \(snapshot.sha.prefix(12)) after confirming; GitLab applies its merge checks")
                }
            }
        }
        .font(.ds(.meta))
    }
}

struct PipelineSection: View {
    let model: MergeRequestPanelModel
    let snapshot: MergeRequestSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            if let pipeline = snapshot.pipeline {
                let failed = pipeline.failedJobs
                HStack {
                    SectionTitle(title: "Pipeline #\(pipeline.id)", trailing: pipeline.sha.map { "at \($0.prefix(8))" })
                }
                HStack(spacing: DS.Space.s8) {
                    Label(snapshot.pipelineSummary.text, systemImage: snapshot.pipelineSummary.symbolName)
                        .foregroundStyle(GitLabTone.pipeline(snapshot.pipelineSummary))
                    Spacer()
                    if !failed.isEmpty {
                        Toggle("Failures only", isOn: Bindable(model).failuresOnly).font(.ds(.meta))
                    }
                    if let url = pipeline.webURL.flatMap(URL.init(string:)) {
                        Button("Open") { model.openURL(url, false) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                    }
                }
                let stages = pipeline.stages.compactMap { stage -> PipelineStage? in
                    guard model.failuresOnly else { return stage }
                    let jobs = stage.jobs.filter { $0.isFailure }
                    return jobs.isEmpty ? nil : PipelineStage(name: stage.name, jobs: jobs)
                }
                ForEach(stages) { stage in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DS.Space.s4) {
                            Text(stage.name.capitalized).font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
                            Text(PipelineJob(id: 0, name: "", status: stage.status).label.lowercased()).foregroundStyle(SwiftUI.Color.ds.text3)
                        }
                        ForEach(stage.jobs) { job in JobRow(model: model, snapshot: snapshot, job: job) }
                    }
                    .padding(.leading, DS.Space.s4)
                }
            } else {
                SectionTitle(title: "Pipeline")
                Text("No pipeline for the head commit.").foregroundStyle(SwiftUI.Color.ds.text3)
            }
        }
        .font(.ds(.meta))
    }
}

struct JobRow: View {
    let model: MergeRequestPanelModel
    let snapshot: MergeRequestSnapshot
    let job: PipelineJob

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s6) {
                Text(job.glyph).foregroundStyle(GitLabTone.job(job)).frame(width: 12).accessibilityHidden(true)
                Text(job.name).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                Text(job.label + (job.allowFailure == true && job.isFailure ? " (allowed)" : "")).foregroundStyle(GitLabTone.job(job))
                if let duration = job.duration { Text("\(Int(duration))s").monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text4) }
                Spacer(minLength: 0)
                Button("Log") { model.showLog(snapshot.ref, job) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).help("Show the end of this job's log")
                if job.isRetryable {
                    Button("Retry") { Task { await model.retry(snapshot.ref, job) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .disabled(model.isBusy("retry-\(job.id)")).help("Retry this job on GitLab (needs write actions in Settings ▸ GitLab)")
                }
                if job.isManual {
                    Button("Run…") { Task { await model.play(snapshot.ref, job) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                        .disabled(model.isBusy("play-\(job.id)")).help("Run this manual job (may deploy; asks first)")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(job.name), \(job.label)")
            if job.isFailure && job.allowFailure != true { TriageBox(model: model, snapshot: snapshot, job: job) }
        }
    }
}

/// The failing job's excerpt (first error-looking block and the tail, sanitised) with Send to Agent.
struct TriageBox: View {
    let model: MergeRequestPanelModel
    let snapshot: MergeRequestSnapshot
    let job: PipelineJob

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            if let excerpt = model.excerpt(snapshot.ref, job) {
                ScrollView([.horizontal, .vertical]) {
                    Text(excerpt.text).font(.ds(.codeSmall)).foregroundStyle(SwiftUI.Color.ds.text2).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).padding(DS.Space.s6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(SwiftUI.Color.ds.codeFill))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                .accessibilityLabel("Log excerpt of \(job.name)")
                Text("Excerpt of the log (secret-looking values redacted; \(excerpt.linesRead) lines read\(excerpt.headOmitted ? ", end of the log only" : "")).")
                    .foregroundStyle(SwiftUI.Color.ds.text3)
            } else if model.isLoadingExcerpt(snapshot.ref, job) {
                Text("Reading the log…").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            HStack(spacing: DS.Space.s6) {
                if model.excerpt(snapshot.ref, job) == nil {
                    Button("Show Excerpt") { Task { await model.loadExcerpt(snapshot.ref, job) } }
                }
                Button("Send to Agent") { Task { await model.sendToAgent(snapshot.ref, job) } }
                    .help("Put this excerpt into the composer, quoted as untrusted GitLab output; you review and send it")
            }
        }
        .font(.ds(.meta))
        .padding(.leading, 18)
    }
}

struct DiscussionsSection: View {
    let snapshot: MergeRequestSnapshot
    static let shown = 20

    var body: some View {
        let all = (snapshot.discussions ?? []).filter { !$0.isSystem }
        let ordered = all.filter(\.isUnresolved) + all.filter { !$0.isUnresolved }.reversed()
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            SectionTitle(title: "Discussions", trailing: snapshot.unresolvedText)
            if snapshot.discussions == nil {
                Text("Not loaded yet.").foregroundStyle(SwiftUI.Color.ds.text3)
            } else if ordered.isEmpty {
                Text("No discussions.").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            ForEach(ordered.prefix(Self.shown)) { discussion in
                let first = discussion.notes.first { !$0.system }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s6) {
                        Text(discussion.isUnresolved ? "○" : discussion.isResolvable ? "✓" : "•")
                            .foregroundStyle(discussion.isUnresolved ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.text3)
                        Text("@\(first?.author ?? "")").font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
                        if let position = discussion.position { Text(position).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.head) }
                        Spacer(minLength: 0)
                        Text(discussion.isUnresolved ? "Unresolved" : discussion.isResolvable ? "Resolved" : "Comment").foregroundStyle(SwiftUI.Color.ds.text3)
                    }
                    Text(first?.body ?? "").foregroundStyle(SwiftUI.Color.ds.text).lineLimit(3).textSelection(.enabled)
                    if discussion.notes.count > 1 { Text("\(discussion.notes.count - 1) more in thread").foregroundStyle(SwiftUI.Color.ds.text3) }
                }
                .accessibilityElement(children: .combine)
            }
            if ordered.count > Self.shown { Text("\(ordered.count - Self.shown) more: open the MR in GitLab.").foregroundStyle(SwiftUI.Color.ds.text3) }
        }
        .font(.ds(.meta))
    }
}

struct BabysitSection: View {
    let model: MergeRequestPanelModel
    let link: LinkedMergeRequest

    var body: some View {
        let service = model.service
        let watch = model.threadID.flatMap { service.watch($0, link.ref.url) }
        let log = model.threadID.map { service.wakeLog($0, link.ref.url) } ?? []
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            SectionTitle(title: "Babysit", trailing: link.watching ? ((watch?.wakes ?? 0) == 1 ? "1 wake" : "\(watch?.wakes ?? 0) wakes") : nil)
            HStack(spacing: DS.Space.s6) {
                Button(link.watching ? "Stop Babysitting" : "Babysit this MR") { Task { await model.setWatching(link, !link.watching) } }
                    .buttonStyle(DSButtonStyle(link.watching ? .outline : .primary, size: .small))
                    .help(link.watching ? "Stop waking this thread for this MR" : "Wake this thread once per event: pipeline result, new comments, approvals, merge or close")
                if link.watching, let watch {
                    if watch.heldForRedaction == true {
                        Label("Updates held: the GitLab token could not be read from the Keychain to redact them", systemImage: "lock")
                            .foregroundStyle(SwiftUI.Color.ds.warningText)
                    } else if let until = watch.deferredUntil {
                        Label("Budget reached; next wake \(ExtrasTime.relative(until, now: model.now()))", systemImage: "hourglass").foregroundStyle(SwiftUI.Color.ds.warningText)
                    } else if let next = model.threadID.flatMap({ service.nextPollDate($0, link.ref.url) }) {
                        Label("Next check \(ExtrasTime.relative(next, now: model.now()))", systemImage: "eye").foregroundStyle(SwiftUI.Color.ds.infoText)
                    }
                }
            }
            if let reason = watch?.stoppedReason, !link.watching || watch?.stoppedReason != nil {
                Label("Stopped: \(reason)", systemImage: "eye.slash").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            if link.watching {
                Text(service.babysitPolicy.summary).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(log.prefix(6)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Text(Self.word(entry.outcome)).font(.ds(.metaEmph)).foregroundStyle(Self.tone(entry.outcome)).frame(width: 64, alignment: .leading)
                    Text(entry.summary).foregroundStyle(SwiftUI.Color.ds.text2).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(ExtrasTime.relative(entry.at, now: model.now())).foregroundStyle(SwiftUI.Color.ds.text4)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.ds(.meta))
    }

    static func word(_ outcome: MergeRequestWakeLogEntry.Outcome) -> String {
        switch outcome {
        case .delivered: "Woke"
        case .absorbed: "Quiet"
        case .deferred: "Waiting"
        case .failed: "Retrying"
        case .started: "Started"
        case .stopped: "Stopped"
        }
    }

    static func tone(_ outcome: MergeRequestWakeLogEntry.Outcome) -> SwiftUI.Color {
        switch outcome {
        case .delivered: SwiftUI.Color.ds.infoText
        case .deferred, .failed: SwiftUI.Color.ds.warningText
        default: SwiftUI.Color.ds.text3
        }
    }
}

/// The open job log: header with Back, the job and pipeline, Open in GitLab; the log virtualised below.
struct JobLogPane: View {
    let model: MergeRequestPanelModel
    let open: MergeRequestPanelModel.OpenLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s6) {
                Button {
                    model.closeLog()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(DSButtonStyle(.ghost, size: .small))
                .keyboardShortcut(.cancelAction)
                Text(open.job.glyph).foregroundStyle(GitLabTone.job(open.job))
                Text(open.job.name).font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                Text(open.job.label).font(.ds(.meta)).foregroundStyle(GitLabTone.job(open.job))
                Spacer()
                Button("Reload") { Task { await model.loadLog() } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                if let url = open.job.webURL.flatMap(URL.init(string:)) {
                    Button("Open in GitLab") { model.openURL(url, false) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                }
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s8)
            Text("\(open.ref) · job #\(open.job.id) · stage \(open.job.stage)").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                .padding(.horizontal, DS.Space.s12).padding(.bottom, DS.Space.s6)
            SwiftUI.Color.ds.border.frame(height: 1)
            switch model.log {
            case .idle, .loading:
                Text("Reading the log…").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s12)
                Spacer()
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                    .fixedSize(horizontal: false, vertical: true).padding(DS.Space.s12)
                Spacer()
            case .loaded(let parsed, let headOmitted, let total):
                if headOmitted || parsed.omittedLines > 0 {
                    Text("Showing the end of the log\(total.map { " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) in all)" } ?? ""). Open in GitLab for all of it.")
                        .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).padding(.horizontal, DS.Space.s12).padding(.vertical, DS.Space.s4)
                }
                JobLogRepresentable(log: parsed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
