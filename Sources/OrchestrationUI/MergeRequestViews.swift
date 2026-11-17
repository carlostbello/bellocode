import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Words for MR chips and rows (status is never colour only: a glyph and words every time).
public enum MergeRequestText {
    /// "!42 Open · ✓ Pipeline passed" (header chip). Draft MRs say "Draft".
    public static func chip(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" + (link.watching ? " · Watching" : "") }
        var parts = ["!\(link.ref.iid) \(snapshot.stateLabel)"]
        if snapshot.state == .opened {
            let pipeline = snapshot.pipelineSummary
            if pipeline != .none { parts.append("\(pipeline.glyph) \(pipeline.text)") }
        }
        return parts.joined(separator: " · ")
    }

    /// "!42 ✓" (sidebar: compact).
    public static func compact(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "!\(link.ref.iid)" }
        if snapshot.state.isTerminal { return "!\(link.ref.iid) \(snapshot.state.label)" }
        let pipeline = snapshot.pipelineSummary
        return "!\(link.ref.iid)" + (snapshot.draft ? " Draft" : "") + (pipeline == .none ? "" : " \(pipeline.glyph)")
    }

    public static func accessibility(_ link: LinkedMergeRequest, _ snapshot: MergeRequestSnapshot?) -> String {
        guard let snapshot else { return "Merge request \(link.ref.iid)" }
        return "Merge request \(link.ref.iid), \(snapshot.title), \(snapshot.stateLabel), \(snapshot.approvals.label), \(snapshot.pipelineSummary.text), "
            + snapshot.unresolvedText + (link.watching ? ", watching" : "") + (snapshot.truncationNote.map { ". \($0)" } ?? "")
    }

    public static func source(_ source: MergeRequestLinkSource) -> String {
        switch source {
        case .agent: "linked by the agent"
        case .branch: "this thread's branch"
        case .output: "pushed from this thread"
        case .user: "linked by you"
        }
    }
}

/// View state of the MR section (link field, undo of the last unlink).
@MainActor
@Observable
public final class MergeRequestPanelModel {
    public let service: MergeRequestService
    public private(set) var threadID: SessionID?
    public var linkText = ""
    public private(set) var message: String?
    public private(set) var lastUnlinked: (thread: SessionID, link: LinkedMergeRequest)?
    /// Opens a URL: in the default browser, or the built-in one (`builtIn`).
    @ObservationIgnored public var openURL: (URL, Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }
    @ObservationIgnored public var openSettings: () -> Void = {}
    @ObservationIgnored public var now: () -> Date = Date.init

    public init(service: MergeRequestService) {
        self.service = service
    }

    public func display(_ id: SessionID?) {
        guard id != threadID else { return }
        threadID = id
        message = nil
        if let id { Task { await service.refresh(thread: id) } }
    }

    public var links: [LinkedMergeRequest] { threadID.map(service.links(for:)) ?? [] }

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
}

/// The "Merge Requests" right-panel tab: each linked MR with title, state, approvals, pipeline (jobs with links),
/// unresolved discussions, watch state and why the thread last woke; link (URL or !iid), unlink with Undo, watch, open
/// in the default or built-in browser. Without a configured instance it says how to connect GitLab.
public struct MergeRequestPanelView: View {
    let model: MergeRequestPanelModel

    public init(model: MergeRequestPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s6) {
                Text("Merge Requests").font(.ds(.title))
                Spacer()
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
            .padding(.horizontal, DS.Space.s8)
            .padding(.vertical, DS.Space.s6)
            if model.service.instances.isEmpty || !model.service.instanceProblems.isEmpty {
                connectNotice
            }
            SwiftUI.Color.ds.border.frame(height: 1)
            if model.threadID == nil {
                Text("Select a thread to see its merge requests.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.s8) {
                        if model.links.isEmpty {
                            Text("No merge requests linked to this thread. Agents link them with link_merge_requests; an open MR for this thread's branch, or one a git push here prints, is linked automatically.")
                                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.links) { link in MergeRequestCard(model: model, link: link) }
                        linkField
                        if let last = model.lastUnlinked {
                            HStack {
                                Text("Unlinked \(last.link.ref.description).").font(.ds(.meta))
                                Button("Undo") { Task { await model.undoUnlink() } }.buttonStyle(DSButtonStyle(.ghost, size: .small)).font(.ds(.meta))
                            }
                        }
                        if let message = model.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DS.Space.s8)
                }
            }
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }

    private var connectNotice: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            if model.service.instances.isEmpty {
                Label("Connect GitLab: add your instance and an access token in Settings ▸ GitLab.", systemImage: "link.badge.plus")
            }
            ForEach(model.service.instanceProblems.sorted(by: { $0.key < $1.key }), id: \.key) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.warningText)
            }
            Button("Open GitLab Settings…") { model.openSettings() }.buttonStyle(DSButtonStyle(.ghost, size: .small))
        }
        .font(.ds(.meta))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Space.s8)
        .padding(.bottom, DS.Space.s6)
    }

    private var linkField: some View {
        HStack(spacing: DS.Space.s6) {
            TextField("MR URL or !123", text: Bindable(model).linkText)
                .textFieldStyle(DSTextFieldStyle())
                .onSubmit { Task { await model.link() } }
                .accessibilityLabel("Merge request to link: URL or !number")
            Button("Link") { Task { await model.link() } }
                .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }
}

struct MergeRequestCard: View {
    let model: MergeRequestPanelModel
    let link: LinkedMergeRequest

    var body: some View {
        let snapshot = model.service.snapshots[link.ref.url]
        let watch = model.threadID.flatMap { model.service.watch($0, link.ref.url) }
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                Image(systemName: snapshot?.state.symbolName ?? "arrow.triangle.pull")
                    .foregroundStyle(stateColor(snapshot)).accessibilityHidden(true)
                Text("!\(link.ref.iid) ").monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                    + Text(snapshot?.title ?? link.ref.description).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .lineLimit(2)
            Text(detailLine(snapshot)).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.middle)
            if let snapshot {
                HStack(spacing: DS.Space.s6) {
                    Text(snapshot.stateLabel)
                    Text("·").foregroundStyle(SwiftUI.Color.ds.text4)
                    Text(snapshot.approvals.label)
                    Text("·").foregroundStyle(SwiftUI.Color.ds.text4)
                    Label(snapshot.pipelineSummary.text, systemImage: snapshot.pipelineSummary.symbolName)
                        .foregroundStyle(pipelineColor(snapshot.pipelineSummary))
                    if snapshot.unresolvedDiscussions > 0 {
                        Text("·").foregroundStyle(SwiftUI.Color.ds.text4)
                        Label("\(snapshot.unresolvedDiscussions) unresolved", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    }
                }
                .font(.ds(.meta))
                if let note = snapshot.truncationNote {
                    Label(note, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                }
                if let pipeline = snapshot.pipeline, !pipeline.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pipeline.jobs.prefix(12)) { job in
                            HStack(spacing: DS.Space.s4) {
                                Text(job.status == "success" ? "✓" : job.isFailure ? "✕" : job.status == "running" ? "◌" : "–")
                                    .foregroundStyle(job.isFailure ? SwiftUI.Color.ds.dangerText : SwiftUI.Color.ds.text3).frame(width: 12)
                                Text(job.name).lineLimit(1)
                                if !job.stage.isEmpty { Text(job.stage).foregroundStyle(SwiftUI.Color.ds.text4) }
                                Text(job.label).foregroundStyle(SwiftUI.Color.ds.text3)
                                Spacer(minLength: 0)
                                if let url = job.webURL.flatMap(URL.init(string:)) {
                                    Button("Log") { model.openURL(url, false) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
                                }
                            }
                            .font(.ds(.meta))
                            .accessibilityElement(children: .combine)
                        }
                        if pipeline.jobs.count > 12 { Text("\(pipeline.jobs.count - 12) more jobs").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
                        if let url = pipeline.webURL.flatMap(URL.init(string:)) {
                            Button("Pipeline #" + String(pipeline.id)) { model.openURL(url, false) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).font(.ds(.meta))
                        }
                    }
                    .padding(.leading, DS.Space.s12)
                }
            } else if let problem = model.service.problems[link.ref.url] {
                Label(problem, systemImage: "exclamationmark.triangle").font(.ds(.meta))
                    .foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking GitLab…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            watchLine(watch)
            HStack(spacing: DS.Space.s6) {
                Button(link.watching ? "Stop Watching" : "Watch") { Task { await model.setWatching(link, !link.watching) } }
                    .help(link.watching ? "Stop waking this thread for this MR" : "Wake this thread when the pipeline finishes, approvals change, comments arrive, or it is merged or closed")
                Button("Open") { if let url = URL(string: snapshot?.webURL ?? link.ref.url) { model.openURL(url, false) } }
                    .help("Open on GitLab in your default browser")
                Button("Open in BelloCode") { if let url = URL(string: snapshot?.webURL ?? link.ref.url) { model.openURL(url, true) } }
                    .help("Open in the built-in browser")
                Spacer()
                Button("Unlink") { Task { await model.unlink(link) } }.help("Unlink from this thread (Undo is offered)")
            }
            .controlSize(.small)
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .padding(DS.Space.s6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MergeRequestText.accessibility(link, snapshot))
    }

    private func detailLine(_ snapshot: MergeRequestSnapshot?) -> String {
        var parts = [link.ref.projectPath]
        if let snapshot, !snapshot.sourceBranch.isEmpty { parts.append("\(snapshot.sourceBranch) → \(snapshot.targetBranch)") }
        if let snapshot, !snapshot.author.isEmpty { parts.append("by \(snapshot.author)") }
        parts.append(MergeRequestText.source(link.source))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func watchLine(_ watch: MergeRequestWatchRecord?) -> some View {
        if link.watching || watch?.stoppedReason != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let reason = watch?.stoppedReason {
                    Label("Watch stopped: \(reason)", systemImage: "eye.slash").foregroundStyle(SwiftUI.Color.ds.text3)
                } else {
                    let next = model.threadID.flatMap { model.service.nextPollDate($0, link.ref.url) }
                    Label(next.map { "Watching · next check \(ExtrasTime.relative($0, now: model.now()))" } ?? "Watching", systemImage: "eye")
                        .foregroundStyle(SwiftUI.Color.ds.infoText)
                }
                if let text = watch?.lastWakeText, let date = watch?.lastWake {
                    Text("Woke the thread \(ExtrasTime.relative(date, now: model.now())): \(text)").foregroundStyle(SwiftUI.Color.ds.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.ds(.meta))
        }
    }

    private func stateColor(_ snapshot: MergeRequestSnapshot?) -> Color {
        switch snapshot?.state {
        case .opened: snapshot?.draft == true ? .secondary : SwiftUI.Color.ds.successText
        case .merged: Color(nsColor: .systemPurple)
        case .closed, .locked: SwiftUI.Color.ds.dangerText
        case nil: .secondary
        }
    }

    private func pipelineColor(_ summary: PipelineSummary) -> Color {
        switch summary {
        case .passed: SwiftUI.Color.ds.successText
        case .failed: SwiftUI.Color.ds.dangerText
        case .running, .manual: SwiftUI.Color.ds.infoText
        case .none, .canceled: .secondary
        }
    }
}

/// Settings ▸ GitLab: instances (base URL, path prefix allowed) and their access tokens. A token is typed once into a
/// secure field and goes straight to the Keychain; it is never shown again. "Test" asks GitLab who the token is.
@MainActor
@Observable
public final class GitLabSettingsModel {
    public let service: MergeRequestService
    public var baseURL = ""
    public var token = ""
    /// The explicit, per-instance choice to send the token over plain HTTP (shown only for an http:// address).
    public var allowPlainHTTP = false
    public var isPlainHTTPAddress: Bool { baseURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") }
    public private(set) var results: [String: String] = [:]
    public private(set) var message: String?

    public init(service: MergeRequestService) { self.service = service }

    public func save() async {
        let secret = token.isEmpty ? nil : SecretValue(token)
        token = ""
        do {
            let instance = try await service.saveInstance(baseURL: baseURL, token: secret, allowPlainHTTP: isPlainHTTPAddress && allowPlainHTTP)
            baseURL = ""
            allowPlainHTTP = false
            message = nil
            if secret != nil { await test(instance) }
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func replaceToken(_ instance: GitLabInstance) async {
        guard !token.isEmpty else { return }
        let secret = SecretValue(token)
        token = ""
        _ = try? await service.saveInstance(baseURL: instance.baseURL, token: secret)
        await test(instance)
    }

    public func test(_ instance: GitLabInstance) async {
        switch await service.testConnection(instance) {
        case .success(let user): results[instance.baseURL] = "Connected as \(user)"
        case .failure(let error): results[instance.baseURL] = error.description
        }
    }

    public func remove(_ instance: GitLabInstance) async {
        await service.removeInstance(instance)
        results[instance.baseURL] = nil
    }
}

public struct GitLabSettingsView: View {
    let model: GitLabSettingsModel
    let confirmRemove: (GitLabInstance) -> Bool

    public init(model: GitLabSettingsModel, confirmRemove: @escaping (GitLabInstance) -> Bool) {
        self.model = model
        self.confirmRemove = confirmRemove
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            Text("Merge requests are read from your GitLab instance with a personal or project access token (read_api scope). The token is kept in your Keychain, sent only to that instance, and never shown again or given to agents.")
                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            if model.service.instances.isEmpty {
                Text("No GitLab instance yet.").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            ForEach(model.service.instances) { instance in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: model.service.instancesWithToken.contains(instance.baseURL) ? "key.fill" : "key.slash")
                            .foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
                        Text(instance.baseURL).font(.body.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer()
                        Button("Test") { Task { await model.test(instance) } }.disabled(!model.service.instancesWithToken.contains(instance.baseURL))
                        Button("Replace Token") { Task { await model.replaceToken(instance) } }.disabled(model.token.isEmpty)
                            .help("Type the new token in the field below, then click Replace Token")
                        Button("Remove…") { if confirmRemove(instance) { Task { await model.remove(instance) } } }
                    }
                    if instance.isPlainHTTP {
                        Label("Plain HTTP: the token crosses the network unencrypted (allowed for this instance).", systemImage: "exclamationmark.triangle")
                            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                    }
                    Text(status(instance)).font(.ds(.meta))
                        .foregroundStyle(model.service.instanceProblems[instance.baseURL] != nil ? SwiftUI.Color.ds.dangerText : SwiftUI.Color.ds.text3)
                }
                SwiftUI.Color.ds.border.frame(height: 1)
            }
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                HStack(spacing: DS.Space.s10) {
                    Text("Instance URL").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 96, alignment: .trailing)
                    TextField("", text: Bindable(model).baseURL, prompt: Text("https://gitlab.example.com")).textFieldStyle(DSTextFieldStyle())
                        .accessibilityLabel("Instance URL")
                }
                HStack(spacing: DS.Space.s10) {
                    Text("Access token").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 96, alignment: .trailing)
                    SecureField("", text: Bindable(model).token, prompt: Text("glpat-…")).textFieldStyle(DSTextFieldStyle())
                        .accessibilityLabel("GitLab access token")
                }
                if model.isPlainHTTPAddress {
                    Toggle("Allow unencrypted HTTP for this instance (the token is sent in clear text)", isOn: Bindable(model).allowPlainHTTP)
                        .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.warningText)
                }
                HStack {
                    Spacer()
                    Button("Add Instance") { Task { await model.save() } }
                        .buttonStyle(DSButtonStyle(.primary, size: .small))
                        .disabled(model.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message = model.message { Text(message).foregroundStyle(SwiftUI.Color.ds.dangerText) }
            Text("Self-managed instances with a private CA work once that CA is trusted in Keychain Access (System trust store).")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
    }

    private func status(_ instance: GitLabInstance) -> String {
        if let problem = model.service.instanceProblems[instance.baseURL] { return problem }
        if let result = model.results[instance.baseURL] { return result }
        return model.service.instancesWithToken.contains(instance.baseURL) ? "Token saved in the Keychain." : "No token yet: type one below and click Replace Token."
    }
}
