import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Words for PR chips and rows (status is never colour only: a glyph and words every time).
public enum PullRequestText {
    /// "#42 Open · ✓ 3 checks passed", for the header chip and sidebar.
    public static func chip(_ link: LinkedPullRequest, _ snapshot: PullRequestSnapshot?) -> String {
        guard let snapshot else { return "#\(link.ref.number)" + (link.watching ? " · Watching" : "") }
        var parts = ["#\(link.ref.number) \(snapshot.state.label)"]
        if snapshot.state == .open || snapshot.state == .draft {
            let checks = snapshot.checksSummary
            if checks != .none { parts.append("\(checks.glyph) \(checks.text)") }
        }
        return parts.joined(separator: " · ")
    }

    /// "#42 ✓" (sidebar: compact).
    public static func compact(_ link: LinkedPullRequest, _ snapshot: PullRequestSnapshot?) -> String {
        guard let snapshot else { return "#\(link.ref.number)" }
        if snapshot.state.isTerminal { return "#\(link.ref.number) \(snapshot.state.label)" }
        let checks = snapshot.checksSummary
        return "#\(link.ref.number)" + (checks == .none ? "" : " \(checks.glyph)")
    }

    public static func accessibility(_ link: LinkedPullRequest, _ snapshot: PullRequestSnapshot?) -> String {
        guard let snapshot else { return "Pull request \(link.ref.number)" }
        return "Pull request \(link.ref.number), \(snapshot.title), \(snapshot.state.label), \(snapshot.reviewDecision.label), \(snapshot.checksSummary.text)"
            + (link.watching ? ", watching" : "")
    }

    public static func source(_ source: PullRequestLinkSource) -> String {
        switch source {
        case .agent: "linked by the agent"
        case .branch: "this thread's branch"
        case .output: "created in this thread"
        case .user: "linked by you"
        }
    }
}

/// View state of the PR section (link field, undo of the last unlink).
@MainActor
@Observable
public final class PullRequestPanelModel {
    public let service: PullRequestService
    public private(set) var threadID: SessionID?
    public var linkText = ""
    public private(set) var message: String?
    public private(set) var lastUnlinked: (thread: SessionID, link: LinkedPullRequest)?
    /// Opens a URL: in the default browser, or the built-in one (`builtIn`).
    @ObservationIgnored public var openURL: (URL, Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }
    @ObservationIgnored public var now: () -> Date = Date.init

    public init(service: PullRequestService) {
        self.service = service
    }

    public func display(_ id: SessionID?) {
        guard id != threadID else { return }
        threadID = id
        message = nil
        if let id { Task { await service.refresh(thread: id) } }
    }

    public var links: [LinkedPullRequest] { threadID.map(service.links(for:)) ?? [] }

    public func link() async {
        guard let threadID else { return }
        guard let ref = PullRequestRef.parse(linkText) else {
            message = "That is not a GitHub pull request URL (https://github.com/OWNER/REPO/pull/N)."
            return
        }
        do {
            try await service.link([ref], to: threadID, source: .user)
            linkText = ""
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    /// Unlinks at once; `undoUnlink` puts it back (UX rule: reversible actions apply immediately with Undo).
    public func unlink(_ link: LinkedPullRequest) async {
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
        try? await service.link([last.link.ref], to: last.thread, source: last.link.source, watch: last.link.watching)
    }

    public func setWatching(_ link: LinkedPullRequest, _ watching: Bool) async {
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

/// The "Pull Requests" right-panel tab: each linked PR with title, state, review decision, checks (with links),
/// watch state and why the thread last woke; link, unlink (with Undo), watch, open in the default or built-in browser.
public struct PullRequestPanelView: View {
    let model: PullRequestPanelModel

    public init(model: PullRequestPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Text("Pull Requests").font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Check GitHub now")
                .disabled(model.links.isEmpty)
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            if let access = model.service.access, access != .cli {
                Label(access.label, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.m).padding(.bottom, DS.Spacing.s)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if model.threadID == nil {
                empty("Select a thread to see its pull requests.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.m) {
                        if model.links.isEmpty {
                            Text("No pull requests linked to this thread. Agents link them with link_pull_requests, and a gh pr create run here links its PR automatically.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.links) { link in
                            PullRequestCard(model: model, link: link)
                        }
                        linkField
                        if let last = model.lastUnlinked {
                            HStack {
                                Text("Unlinked \(last.link.ref.description).").font(.caption)
                                Button("Undo") { Task { await model.undoUnlink() } }.buttonStyle(.link).font(.caption)
                            }
                        }
                        if let message = model.message {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(Color(nsColor: DS.Palette.failure))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DS.Spacing.m)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }

    private var linkField: some View {
        HStack(spacing: DS.Spacing.s) {
            TextField("https://github.com/owner/repo/pull/123", text: Bindable(model).linkText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.link() } }
                .accessibilityLabel("Pull request URL to link")
            Button("Link") { Task { await model.link() } }
                .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PullRequestCard: View {
    let model: PullRequestPanelModel
    let link: LinkedPullRequest

    var body: some View {
        let snapshot = model.service.snapshots[link.ref.url]
        let watch = model.threadID.flatMap { model.service.watch($0, link.ref.url) }
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Image(systemName: snapshot?.state.symbolName ?? "arrow.triangle.pull")
                    .foregroundStyle(stateColor(snapshot?.state))
                    .accessibilityHidden(true)
                Text("#\(link.ref.number) ").monospacedDigit().foregroundStyle(.secondary)
                    + Text(snapshot?.title ?? link.ref.description).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .lineLimit(2)
            Text(detailLine(snapshot)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let snapshot {
                HStack(spacing: DS.Spacing.s) {
                    Text(snapshot.state.label)
                    Text("·").foregroundStyle(.tertiary)
                    Text(snapshot.reviewDecision.label)
                    Text("·").foregroundStyle(.tertiary)
                    Label(snapshot.checksSummary.text, systemImage: snapshot.checksSummary.symbolName)
                        .foregroundStyle(checksColor(snapshot.checksSummary))
                }
                .font(.caption)
                if !snapshot.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.checks.prefix(12), id: \.id) { check in
                            HStack(spacing: DS.Spacing.xs) {
                                Text(check.status == .completed ? (check.conclusion?.isFailure == true ? "✕" : "✓") : "◌")
                                    .foregroundStyle(check.conclusion?.isFailure == true ? Color(nsColor: DS.Palette.failure) : .secondary)
                                    .frame(width: 12)
                                Text(check.name).lineLimit(1)
                                Text(check.label).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                if let url = check.url.flatMap(URL.init(string:)) {
                                    Button("Details") { model.openURL(url, false) }.buttonStyle(.link)
                                }
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                        if snapshot.checks.count > 12 {
                            Text("\(snapshot.checks.count - 12) more checks").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, DS.Spacing.l)
                }
            } else if let problem = model.service.problems[link.ref.url] {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(Color(nsColor: DS.Palette.failure)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking GitHub…").font(.caption).foregroundStyle(.secondary)
            }
            watchLine(watch)
            HStack(spacing: DS.Spacing.s) {
                Button(link.watching ? "Stop Watching" : "Watch") { Task { await model.setWatching(link, !link.watching) } }
                    .help(link.watching ? "Stop waking this thread for this PR" : "Wake this thread when checks finish, reviews or comments arrive, or it is merged or closed")
                Button("Open") { if let url = URL(string: link.ref.url) { model.openURL(url, false) } }
                    .help("Open on GitHub in your default browser")
                Button("Open in BelloCode") { if let url = URL(string: link.ref.url) { model.openURL(url, true) } }
                    .help("Open in the built-in browser")
                Spacer()
                Button("Unlink") { Task { await model.unlink(link) } }.help("Unlink from this thread (Undo is offered)")
            }
            .controlSize(.small)
        }
        .padding(DS.Spacing.s)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PullRequestText.accessibility(link, snapshot))
    }

    private func detailLine(_ snapshot: PullRequestSnapshot?) -> String {
        var parts = [link.ref.slug]
        if let snapshot, !snapshot.headBranch.isEmpty { parts.append("\(snapshot.headBranch) → \(snapshot.baseBranch)") }
        if let snapshot, !snapshot.author.isEmpty { parts.append("by \(snapshot.author)") }
        parts.append(PullRequestText.source(link.source))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func watchLine(_ watch: PullRequestWatchRecord?) -> some View {
        if link.watching || watch?.stoppedReason != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let reason = watch?.stoppedReason {
                    Label("Watch stopped: \(reason)", systemImage: "eye.slash").foregroundStyle(.secondary)
                } else {
                    let next = model.threadID.flatMap { model.service.nextPollDate($0, link.ref.url) }
                    Label(next.map { "Watching · next check \(ExtrasTime.relative($0, now: model.now()))" } ?? "Watching", systemImage: "eye")
                        .foregroundStyle(Color(nsColor: DS.Palette.running))
                }
                if let text = watch?.lastWakeText, let date = watch?.lastWake {
                    Text("Woke the thread \(ExtrasTime.relative(date, now: model.now())): \(text)")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
        }
    }

    private func stateColor(_ state: PullRequestState?) -> Color {
        switch state {
        case .open: Color(nsColor: DS.Palette.success)
        case .merged: Color(nsColor: .systemPurple)
        case .closed: Color(nsColor: DS.Palette.failure)
        case .draft, nil: .secondary
        }
    }

    private func checksColor(_ summary: ChecksSummary) -> Color {
        switch summary {
        case .passing: Color(nsColor: DS.Palette.success)
        case .failing: Color(nsColor: DS.Palette.failure)
        case .pending: Color(nsColor: DS.Palette.running)
        case .none: .secondary
        }
    }
}
