import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// The "Auto" right-panel tab (docs/features/auto-mode.md): the displayed thread's audit log of Auto decisions,
/// escalations, refusals and Full-access risk notices. Bounded (500 per thread, 30 days), labels only. Cached first:
/// what is in memory shows at once, the store fills in older rows.
@MainActor
final class AutoAuditSurfaces {
    private let host = NSViewController()
    private let state = AutoAuditViewState()
    private var hosting: NSHostingController<AutoAuditView>?
    private(set) var context: ThreadSurfaceContext?

    init() { host.view = NSView() }

    func makePanelController() -> NSViewController { host }

    func bind(engine: Engine) {
        guard hosting == nil, let auto = engine.auto else { return }
        let hosting = NSHostingController(rootView: AutoAuditView(auto: auto, state: state))
        hosting.sizingOptions = []
        host.addChild(hosting)
        hosting.view.frame = host.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        host.view.addSubview(hosting.view)
        self.hosting = hosting
        display(context)
    }

    func display(_ context: ThreadSurfaceContext?) {
        self.context = context
        state.sessionID = context?.thread?.session?.id
        state.mode = context?.thread?.session?.permissionMode
        state.expanded = nil
        if let id = state.sessionID, let auto = context?.engine.auto { Task { await auto.loadAudit(id) } }
    }
}

@MainActor
final class AutoAuditViewState: ObservableObject {
    @Published var sessionID: SessionID?
    @Published var mode: PermissionMode?
    @Published var expanded: String?
}

struct AutoAuditView: View {
    let auto: AutoModeService
    @ObservedObject var state: AutoAuditViewState
    @FocusState private var focused: Bool

    private var entries: [AutoAuditEntry] { state.sessionID.flatMap { auto.audit[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SwiftUI.Color.ds.border.frame(height: 1)
            if state.sessionID == nil {
                empty("Open a thread to see its Auto decisions and risk notices.")
            } else if entries.isEmpty {
                empty(state.mode == .auto
                      ? "No decisions yet. Auto-approved actions, escalations and refusals appear here."
                      : "Nothing recorded. In Full access, risky actions BelloCode detects appear here; in Auto, its decisions.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in row(entry) }
                    }
                    .padding(.vertical, DS.Space.s4)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    state.expanded = state.expanded == nil ? entries.first?.id : nil
                    return .handled
                }
            }
            footer
        }
        .background(SwiftUI.Color.ds.canvas)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto audit log")
    }

    private var header: some View {
        let approved = entries.filter { $0.kind == .autoApproved }.count
        let asked = entries.filter { $0.kind == .escalated }.count
        let refused = entries.filter { $0.kind == .denied }.count
        let noticed = entries.filter { $0.kind == .notice }.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: "checkmark.shield").foregroundStyle(SwiftUI.Color.ds.icon)
                Text("Auto audit").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
                Spacer()
                Text(modeLabel).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            Text("\(approved) auto-approved · \(asked) asked you · \(refused) refused · \(noticed) noticed")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
    }

    private var modeLabel: String {
        switch state.mode {
        case .auto: "Mode: Auto"
        case .fullAccess: "Mode: Full access"
        case .ask: "Mode: Ask"
        case .autoEdit: "Mode: Auto-edit"
        case nil: "Mode: opencode default"
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s6) {
            Text("Policy \(RiskPolicy.version) · reviewer \(auto.reviewerModel.map { "\($0.providerID)/\($0.id)" } ?? "server default") · detection is best effort")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text4).lineLimit(1)
            Spacer()
            if let id = state.sessionID, auto.noticeCount(id) > 0 {
                Button("Mark Reviewed") { auto.markReviewed(id) }.buttonStyle(DSButtonStyle(.outline, size: .small))
            }
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s6)
    }

    private func empty(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).multilineTextAlignment(.center).padding(DS.Space.s16)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(_ entry: AutoAuditEntry) -> String {
        switch entry.kind {
        case .autoApproved: "checkmark.circle"
        case .escalated: "hand.raised"
        case .denied: "xmark.octagon"
        case .notice: entry.findings.first?.category.symbolName ?? "exclamationmark.triangle"
        case .interrupt: "stop.circle"
        }
    }

    private func row(_ entry: AutoAuditEntry) -> some View {
        let isExpanded = state.expanded == entry.id
        return Button {
            state.expanded = isExpanded ? nil : entry.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: symbol(entry))
                        .font(.system(size: DS.Size.iconPointMeta))
                        .foregroundStyle(entry.kind == .notice || entry.kind == .escalated ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.icon)
                    Text(entry.title).font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text2)
                    Text(entry.explanation).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(isExpanded ? 4 : 1)
                    Spacer(minLength: DS.Space.s4)
                    Text(RelativeTime.short(entry.at.date)).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text4)
                }
                if isExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        detail("Action", entry.action)
                        if let source = entry.source { detail("Decided by", source.rawValue + (entry.model.map { " (\($0))" } ?? "")) }
                        if !entry.findings.isEmpty { detail("Found", entry.findings.map(\.noticeText).joined(separator: "; ")) }
                        detail("Reason code", entry.reasonCode)
                        if let state = entry.state { detail("State", state) }
                        if let latency = entry.latencyMilliseconds { detail("Took", "\(latency) ms") }
                        detail("Policy", entry.policyVersion)
                    }
                    .padding(.leading, DS.Space.s20)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isExpanded ? SwiftUI.Color.ds.rowActive : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title): \(entry.explanation)")
        .accessibilityHint(isExpanded ? "Collapse details" : "Show details")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
            Text(label).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).frame(width: 78, alignment: .leading)
            Text(value).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text2).textSelection(.enabled)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        let index = state.expanded.flatMap { id in entries.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : entries.count)
        state.expanded = entries[max(0, min(entries.count - 1, index + delta))].id
        return .handled
    }
}
