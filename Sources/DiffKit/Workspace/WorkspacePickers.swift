import AppKit
import DesignSystem
import Engine
import SwiftUI

// The new-thread composer's workspace and branch pickers: compact buttons in the controls bar opening keyboard-first
// popovers (search field focused; ↑/↓ move, Return chooses, Escape closes), like the model picker.

/// "Local ▾" / "New worktree ▾" / "Worktree · name ▾".
public struct WorkspacePickerButton: View {
    @Bindable var draft: WorkspaceDraft
    @StateObject private var isOpen = PickerState(false)

    public init(draft: WorkspaceDraft) { self.draft = draft }

    public var body: some View {
        Button {
            isOpen.value.toggle()
        } label: {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: symbol).font(.system(size: DS.Size.iconPointRow)).foregroundStyle(SwiftUI.Color.ds.icon)
                Text(draft.workspaceLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4)
            }
        }
        .buttonStyle(DSComposerSelectStyle(isOpen: isOpen.value))
        .disabled(draft.repository.phase == .notRepository)
        .help(draft.repository.phase == .notRepository ? "Worktrees need a git repository" : "Where the agent works: local checkout or a worktree (⇧⌘E)")
        .accessibilityLabel("Workspace")
        .accessibilityValue(draft.workspaceLabel)
        .onChange(of: draft.workspaceOpenRequests) { isOpen.value = true }
        .glassPopover(isPresented: $isOpen.value, width: 360) {
            WorkspacePickerView(draft: draft) { isOpen.value = false }
        }
    }

    private var symbol: String {
        switch draft.mode {
        case .local: "laptopcomputer"
        case .newWorktree: "plus.square.on.square"
        case .existingWorktree: "square.on.square"
        }
    }
}

/// The workspace popover's content.
public struct WorkspacePickerView: View {
    @Bindable var draft: WorkspaceDraft
    let close: () -> Void
    @StateObject private var query = PickerState("")
    @StateObject private var highlight = PickerState(0)
    @FocusState private var focused: Bool

    public init(draft: WorkspaceDraft, close: @escaping () -> Void) {
        self.draft = draft
        self.close = close
    }

    struct Option: Identifiable, Hashable {
        enum Kind: Hashable { case local, newWorktree, existing(GitWorktree) }
        var kind: Kind
        var title: String
        var detail: String
        var symbol: String
        var id: String { title + detail }
    }

    var options: [Option] {
        var all: [Option] = [
            Option(kind: .local, title: "Local checkout", detail: (draft.projectDirectory as NSString).abbreviatingWithTildeInPath, symbol: "laptopcomputer"),
            Option(
                kind: .newWorktree, title: "New worktree", detail: "New branch from \(draft.startFromOrigin ? "origin/" : "")\(draft.effectiveBase)",
                symbol: "plus.square.on.square"),
        ]
        all += draft.worktrees.map { worktree in
            Option(
                kind: .existing(worktree), title: worktree.branch ?? "Detached \(worktree.head?.prefix(7) ?? "")",
                detail: (worktree.path as NSString).abbreviatingWithTildeInPath, symbol: "square.on.square")
        }
        guard !query.value.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query.value) || $0.detail.localizedCaseInsensitiveContains(query.value) }
    }

    func isSelected(_ option: Option) -> Bool {
        switch (option.kind, draft.mode) {
        case (.local, .local), (.newWorktree, .newWorktree): true
        case (.existing(let worktree), .existingWorktree): worktree == draft.existingWorktree
        default: false
        }
    }

    func choose(_ option: Option) {
        switch option.kind {
        case .local: draft.mode = .local
        case .newWorktree: draft.mode = .newWorktree
        case .existing(let worktree): draft.chooseWorktree(worktree)
        }
        close()
    }

    public var body: some View {
        let options = options
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                PickerSearchGlyph()
                TextField("Filter workspaces", text: $query.value)
                    .textFieldStyle(.plain)
                    .font(.ds(.body))
                    .foregroundStyle(SwiftUI.Color.ds.text)
                    .focused($focused)
                    .onKeyPress(.downArrow) { highlight.value = min(highlight.value + 1, max(0, options.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlight.value = max(highlight.value - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        if options.indices.contains(highlight.value) { choose(options[highlight.value]) }
                        return .handled
                    }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query.value) { highlight.value = 0 }
                    .accessibilityLabel("Filter workspaces")
            }
            .padding(.horizontal, DS.Space.s12)
            .frame(height: 40)
            SwiftUI.Color.ds.border.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SwiftUI.Color.clear.frame(height: DS.Space.s4)
                        if !draft.worktrees.isEmpty, query.value.isEmpty {
                            EmptyView()
                        }
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            PickerRow(
                                symbol: option.symbol, title: option.title, detail: option.detail, selected: isSelected(option), highlighted: index == highlight.value
                            ) { choose(option) }
                            .id(index)
                        }
                        if options.isEmpty {
                            Text("No matching workspace").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s10)
                        }
                    }
                }
                .onChange(of: highlight.value) { proxy.scrollTo(highlight.value) }
            }
            .padding(.horizontal, DS.Space.s4)
            .frame(maxHeight: 260)
            SwiftUI.Color.ds.border.frame(height: 1)
            VStack(alignment: .leading, spacing: DS.Space.s8) {
                Toggle("Start new worktrees from origin", isOn: $draft.startFromOrigin)
                    .toggleStyle(DSToggleStyle(.checkbox))
                    .font(.ds(.label))
                    .foregroundStyle(SwiftUI.Color.ds.text)
                    .help("Fetch the base branch from origin first, so the worktree starts at the remote's latest commit")
                if draft.mode == .newWorktree {
                    HStack(spacing: 6) {
                        Text("Branch").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                        TextField("Named after the prompt", text: $draft.branchName)
                            .textFieldStyle(DSTextFieldStyle())
                            .accessibilityLabel("New branch name")
                    }
                }
                Text("New worktrees go in \((draft.preferences.parentDirectory(projectDirectory: draft.projectDirectory) as NSString).abbreviatingWithTildeInPath)")
                    .font(.ds(.meta))
                    .foregroundStyle(SwiftUI.Color.ds.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(DS.Space.s12)
        }
        .font(.ds(.body))
        .frame(width: 360)
        .onAppear {
            focused = true
            Task { await draft.reloadWorktrees() }
        }
    }
}

/// "⎇ main ▾" (local), "⎇ new branch from main ▾" (new worktree).
public struct BranchPickerButton: View {
    @Bindable var draft: WorkspaceDraft
    @StateObject private var isOpen = PickerState(false)

    public init(draft: WorkspaceDraft) { self.draft = draft }

    public var body: some View {
        Button {
            if !isOpen.value { draft.repository.loadBranches() }
            isOpen.value.toggle()
        } label: {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: DS.Size.iconPointRow)).foregroundStyle(SwiftUI.Color.ds.icon)
                Text(draft.branchLabel).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SwiftUI.Color.ds.text4)
            }
        }
        .buttonStyle(DSComposerSelectStyle(isOpen: isOpen.value))
        .disabled(draft.mode == .existingWorktree || draft.repository.phase == .notRepository)
        .help(draft.mode == .newWorktree ? "Base branch for the new worktree (⇧⌘B)" : "Branch of the local checkout (⇧⌘B)")
        .accessibilityLabel(draft.mode == .newWorktree ? "Base branch" : "Branch")
        .accessibilityValue(draft.branchLabel)
        .onChange(of: draft.branchOpenRequests) {
            draft.repository.loadBranches()
            isOpen.value = true
        }
        .glassPopover(isPresented: $isOpen.value, width: 360) {
            BranchPickerView(draft: draft) { isOpen.value = false }
        }
    }
}

/// The branch popover: local branches, then remote ones (newest commit first); in local mode the last row creates a
/// branch named by the query.
public struct BranchPickerView: View {
    @Bindable var draft: WorkspaceDraft
    let close: () -> Void
    @StateObject private var query = PickerState("")
    @StateObject private var highlight = PickerState(0)
    @StateObject private var error = PickerState<String?>(nil)
    @FocusState private var focused: Bool

    public init(draft: WorkspaceDraft, close: @escaping () -> Void) {
        self.draft = draft
        self.close = close
    }

    enum Row: Hashable, Identifiable {
        case branch(GitBranch)
        case create(String)
        var id: String {
            switch self {
            case .branch(let branch): branch.id
            case .create(let name): "create:" + name
            }
        }
    }

    var rows: [Row] {
        let branches = draft.repository.branches.filter { query.value.isEmpty || $0.name.localizedCaseInsensitiveContains(query.value) }
        let local = branches.filter { !$0.isRemote }
        let remote = branches.filter(\.isRemote).filter { remote in !local.contains { $0.name == remote.localName } || !query.value.isEmpty }
        var rows = (local + remote).prefix(300).map(Row.branch)
        let trimmed = query.value.trimmingCharacters(in: .whitespaces)
        if draft.mode == .local, !trimmed.isEmpty, !local.contains(where: { $0.name == trimmed }) { rows.append(.create(trimmed)) }
        return rows
    }

    func choose(_ row: Row) {
        switch row {
        case .branch(let branch):
            if draft.mode == .newWorktree {
                draft.baseBranch = branch.isRemote ? branch.localName : branch.name
                if branch.isRemote { draft.startFromOrigin = true }
                close()
            } else {
                Task {
                    do {
                        try await draft.switchLocalBranch(to: branch.isRemote ? branch.localName : branch.name, create: false)
                        close()
                    } catch {
                        self.error.value = (error as? GitError)?.userMessage ?? "Could not switch branches."
                    }
                }
            }
        case .create(let name):
            Task {
                do {
                    try await draft.switchLocalBranch(to: name, create: true)
                    close()
                } catch {
                    self.error.value = (error as? GitError)?.userMessage ?? "Could not create the branch."
                }
            }
        }
    }

    /// "checked out" for the main checkout's branch, "in a worktree" for another worktree's.
    func worktreeNote(_ branch: GitBranch) -> String? {
        guard let path = branch.worktreePath else { return nil }
        func real(_ path: String) -> String { URL(filePath: path).resolvingSymlinksInPath().path }
        return real(path) == real(draft.projectDirectory) ? "checked out" : "in a worktree"
    }

    func isCurrent(_ branch: GitBranch) -> Bool {
        draft.mode == .newWorktree ? (branch.name == draft.effectiveBase && !branch.isRemote) : branch.name == draft.repository.status?.branch
    }

    public var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                PickerSearchGlyph()
                TextField(draft.mode == .newWorktree ? "Base branch" : "Switch to or create a branch", text: $query.value)
                    .textFieldStyle(.plain)
                    .font(.ds(.body))
                    .foregroundStyle(SwiftUI.Color.ds.text)
                    .focused($focused)
                    .onKeyPress(.downArrow) { highlight.value = min(highlight.value + 1, max(0, rows.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlight.value = max(highlight.value - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        if rows.indices.contains(highlight.value) { choose(rows[highlight.value]) }
                        return .handled
                    }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query.value) { highlight.value = 0 }
                    .accessibilityLabel("Filter branches")
                if draft.repository.isLoadingBranches { StatusLabel(.running, showsText: false).accessibilityLabel("Loading branches") }
            }
            .padding(.horizontal, DS.Space.s12)
            .frame(height: 40)
            SwiftUI.Color.ds.border.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SwiftUI.Color.clear.frame(height: DS.Space.s4)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            switch row {
                            case .branch(let branch):
                                PickerRow(
                                    symbol: branch.isRemote ? "cloud" : "arrow.triangle.branch", title: branch.name,
                                    detail: [worktreeNote(branch), branch.commitDate.map { RelativeTime.short($0) }]
                                        .compactMap { $0 }.joined(separator: " · "),
                                    selected: isCurrent(branch), highlighted: index == highlight.value
                                ) { choose(row) }
                                .id(index)
                            case .create(let name):
                                PickerRow(symbol: "plus", title: "Create branch “\(name)”", detail: "from the current commit", selected: false, highlighted: index == highlight.value) {
                                    choose(row)
                                }
                                .id(index)
                            }
                        }
                        if rows.isEmpty {
                            Text(draft.repository.isLoadingBranches ? "Loading branches…" : "No matching branch")
                                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s10)
                        }
                    }
                }
                .onChange(of: highlight.value) { proxy.scrollTo(highlight.value) }
            }
            .padding(.horizontal, DS.Space.s4)
            .frame(maxHeight: 300)
            if let error = error.value {
                SwiftUI.Color.ds.border.frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(SwiftUI.Color.ds.dangerText)
                    Text(error).foregroundStyle(SwiftUI.Color.ds.text)
                }
                .font(.ds(.label))
                .padding(DS.Space.s12)
            }
        }
        .font(.ds(.body))
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

/// A picker row (§6 "Menus, popovers"): 28–34 pt, `r.sm`, keyboard / hover highlight `fillHover`, glyph `icon`, title
/// `body`, detail `meta text3`, and the current choice's check in `accent` in a trailing slot.
struct PickerRow: View {
    var symbol: String
    var title: String
    var detail: String
    var selected: Bool
    var highlighted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s8) {
                Image(systemName: symbol).font(.system(size: DS.Size.iconPointRow)).frame(width: DS.Size.iconBox).foregroundStyle(SwiftUI.Color.ds.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(detail).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: DS.Space.s4)
                Image(systemName: "checkmark")
                    .font(.system(size: DS.Size.iconPointMeta, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color.ds.accent)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(!selected)
                    .accessibilityLabel("Current")
            }
            .padding(.vertical, DS.Space.s4)
        }
        .buttonStyle(DSMenuRowStyle(isHighlighted: highlighted))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The search glyph of a picker's input row (16 pt box, `text3`).
struct PickerSearchGlyph: View {
    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: DS.Size.iconPoint))
            .foregroundStyle(SwiftUI.Color.ds.text3)
            .accessibilityHidden(true)
    }
}

/// View-local state without the SwiftUI macros (Command Line Tools ship no SwiftUI macro plugin).
final class PickerState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
