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
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(draft.workspaceLabel).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.system(size: DS.Typography.current.baseSize - 1))
        }
        .buttonStyle(.borderless)
        .help("Where the agent works: local checkout or a worktree (⇧⌘E)")
        .accessibilityLabel("Workspace")
        .accessibilityValue(draft.workspaceLabel)
        .onChange(of: draft.workspaceOpenRequests) { isOpen.value = true }
        .popover(isPresented: $isOpen.value, arrowEdge: .top) {
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Filter workspaces", text: $query.value)
                    .textFieldStyle(.plain)
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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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
                            Text("No matching workspace").foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
                .onChange(of: highlight.value) { proxy.scrollTo(highlight.value) }
            }
            .frame(maxHeight: 260)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start new worktrees from origin", isOn: $draft.startFromOrigin)
                    .toggleStyle(.checkbox)
                    .help("Fetch the base branch from origin first, so the worktree starts at the remote's latest commit")
                if draft.mode == .newWorktree {
                    HStack(spacing: 6) {
                        Text("Branch").foregroundStyle(.secondary)
                        TextField("Named after the prompt", text: $draft.branchName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("New branch name")
                    }
                }
                Text("New worktrees go in \((draft.preferences.parentDirectory(projectDirectory: draft.projectDirectory) as NSString).abbreviatingWithTildeInPath)")
                    .font(.system(size: DS.Typography.current.baseSize - 2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
        }
        .font(.system(size: DS.Typography.current.baseSize))
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
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(draft.branchLabel).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
            .font(.system(size: DS.Typography.current.baseSize - 1))
        }
        .buttonStyle(.borderless)
        .disabled(draft.mode == .existingWorktree || draft.repository.phase == .notRepository)
        .help(draft.mode == .newWorktree ? "Base branch for the new worktree (⇧⌘B)" : "Branch of the local checkout (⇧⌘B)")
        .accessibilityLabel(draft.mode == .newWorktree ? "Base branch" : "Branch")
        .accessibilityValue(draft.branchLabel)
        .onChange(of: draft.branchOpenRequests) {
            draft.repository.loadBranches()
            isOpen.value = true
        }
        .popover(isPresented: $isOpen.value, arrowEdge: .top) {
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(draft.mode == .newWorktree ? "Base branch" : "Switch to or create a branch", text: $query.value)
                    .textFieldStyle(.plain)
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
                if draft.repository.isLoadingBranches { ProgressView().controlSize(.small).accessibilityLabel("Loading branches") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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
                                .foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
                .onChange(of: highlight.value) { proxy.scrollTo(highlight.value) }
            }
            .frame(maxHeight: 300)
            if let error = error.value {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: DS.Palette.failure))
                    .font(.system(size: DS.Typography.current.baseSize - 1))
                    .padding(10)
            }
        }
        .font(.system(size: DS.Typography.current.baseSize))
        .frame(width: 360)
        .onAppear { focused = true }
    }
}

/// A compact picker row: icon, title, detail, a checkmark for the current choice; highlighted by the keyboard.
struct PickerRow: View {
    var symbol: String
    var title: String
    var detail: String
    var selected: Bool
    var highlighted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: DS.Typography.current.baseSize - 2)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Current") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// View-local state without the SwiftUI macros (Command Line Tools ship no SwiftUI macro plugin).
final class PickerState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
