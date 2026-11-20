import DesignSystem
import Engine
import SwiftUI

/// The git actions popover (header "⌄" next to the quick action; visual-language.md §6 "Menus, popovers"): a status
/// line, then every action with its state. Disabled rows say why (T3 Code `getMenuActionDisabledReason`). Arrow keys
/// move, Return runs, Escape closes.
public struct GitActionsMenuView: View {
    @Bindable var model: GitActionsModel
    let close: () -> Void
    @StateObject private var highlight = PickerState(0)
    @FocusState private var focused: Bool

    public init(model: GitActionsModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        let items = model.items
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s8) {
                Image(systemName: model.repository.status?.hasConflicts == true ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    .font(.system(size: DS.Size.iconPointRow))
                    .foregroundStyle(model.repository.status?.hasConflicts == true ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.icon)
                Text(model.statusLine).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).lineLimit(2)
                Spacer(minLength: 0)
                if model.repository.activity != nil || model.repository.isFetching {
                    StatusLabel(.running, showsText: false).accessibilityLabel(model.repository.activity ?? "Fetching")
                }
            }
            .padding(.horizontal, DS.Space.s12)
            .frame(minHeight: 40)
            SwiftUI.Color.ds.border.frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        run(item)
                    } label: {
                        HStack(spacing: DS.Space.s8) {
                            Image(systemName: item.action.symbolName).font(.system(size: DS.Size.iconPointRow)).frame(width: DS.Size.iconBox)
                                .foregroundStyle(SwiftUI.Color.ds.icon)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).foregroundStyle(item.isEnabled ? SwiftUI.Color.ds.text : SwiftUI.Color.ds.text3)
                                if let reason = item.disabledReason {
                                    Text(reason).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if item.action == model.quickAction.action {
                                DSPillView("Suggested", tone: .neutral)
                            }
                        }
                        .padding(.vertical, DS.Space.s4)
                    }
                    .buttonStyle(DSMenuRowStyle(isHighlighted: index == highlight.value))
                    .disabled(!item.isEnabled)
                    .accessibilityHint(item.disabledReason ?? "")
                }
            }
            .padding(DS.Space.s4)
            if let error = model.lastError {
                SwiftUI.Color.ds.border.frame(height: 1)
                Label(error, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText).padding(DS.Space.s12)
            }
        }
        .font(.ds(.body))
        .frame(width: 380)
        .focusable()
        .focused($focused)
        .onKeyPress(.downArrow) { highlight.value = min(highlight.value + 1, max(0, items.count - 1)); return .handled }
        .onKeyPress(.upArrow) { highlight.value = max(highlight.value - 1, 0); return .handled }
        .onKeyPress(.return) {
            if items.indices.contains(highlight.value) { run(items[highlight.value]) }
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear {
            focused = true
            highlight.value = items.firstIndex { $0.action == model.quickAction.action } ?? 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Git actions")
    }

    func run(_ item: GitActionItem) {
        guard item.isEnabled else { return }
        if !item.action.commits { close() }
        Task { await model.perform(item.action) }
    }
}

/// The commit form (popover from the header): message with Generate, a summary of what is committed, and the three
/// T3 Code buttons. ⌘↩ commits with the suggested follow-up.
public struct GitCommitView: View {
    @Bindable var form: GitCommitModel
    let actions: GitActionsModel
    let close: () -> Void
    @FocusState private var focused: Bool

    public init(form: GitCommitModel, actions: GitActionsModel, close: @escaping () -> Void) {
        self.form = form
        self.actions = actions
        self.close = close
    }

    var choices: [GitAction] {
        let input = actions.input
        return [GitAction.commit, .commitAndPush, .commitPushAndCreateMergeRequest].filter { GitActionPlanner.disabledReason($0, input) == nil }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            HStack {
                Text("Commit to \(actions.repository.status?.branch ?? "HEAD")").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
                Spacer()
                Text(form.summary).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).monospacedDigit()
            }
            TextField("", text: $form.message, prompt: Text("Commit message"), axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.plain)
                .font(.ds(.body))
                .foregroundStyle(SwiftUI.Color.ds.text)
                .focused($focused)
                .padding(.horizontal, DS.Space.s8)
                .padding(.vertical, DS.Space.s6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.canvas))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .stroke(focused ? SwiftUI.Color.ds.accent : SwiftUI.Color.ds.borderStrong, lineWidth: 1))
                .accessibilityLabel("Commit message")
            HStack(spacing: DS.Space.s8) {
                Button {
                    Task { await form.generateMessage() }
                } label: {
                    Label(form.isGenerating ? "Generating…" : "Generate", systemImage: "sparkles")
                }
                .buttonStyle(DSButtonStyle(.ghost, size: .small))
                .disabled(!form.canGenerate)
                .help(form.canGenerate ? "Propose a message with this thread's model from the changes and recent commit subjects" : "Send a first message to generate with the thread's model")
                Spacer()
                if !form.stagedOnly {
                    Text("Stages every change, untracked files included").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                }
            }
            if actions.repository.status?.branch != nil, actions.repository.status?.branch == actions.repository.baseBranch {
                Label("You are on the default branch. Pushing asks to confirm.", systemImage: "exclamationmark.triangle")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.warningText)
            }
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                if form.modelProblem != nil, let open = ModelSettingsLink.open {
                    Button(ModelSettingsLink.title) { open() }.buttonStyle(DSButtonStyle(.outline, size: .small))
                }
            }
            HStack(spacing: DS.Space.s8) {
                Button("Cancel") { close() }.buttonStyle(DSButtonStyle(.ghost, size: .small)).keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(choices, id: \.self) { action in
                    let primary = action == form.followUp || (!choices.contains(form.followUp) && action == choices.last)
                    Button(action.shortTitle) {
                        Task {
                            await actions.finishCommit(form, as: action)
                            if actions.commit == nil { close() }
                        }
                    }
                    .buttonStyle(DSButtonStyle(primary ? .primary : .outline, size: .small, hint: primary ? "⌘↩" : nil))
                    .keyboardShortcut(primary ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(form.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actions.repository.activity != nil)
                }
            }
        }
        .padding(DS.Space.s16)
        .frame(width: 460)
        .onAppear { focused = true }
    }
}

/// "Edit from Here…": what rewinding removes, and the optional file restore (refused, with the reason, in a shared
/// checkout). Rewinding the conversation is permanent in opencode, so it is confirmed; the file restore has Undo.
public struct RewindView: View {
    @Bindable var model: RewindModel
    let close: (Bool) -> Void

    public init(model: RewindModel, close: @escaping (Bool) -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            Text("Edit from here?").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
            Text("This message and everything after it are removed from the thread, and the message returns to the composer. This cannot be undone.")
                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).fixedSize(horizontal: false, vertical: true)
            Text(model.prompt).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(3)
                .padding(DS.Space.s8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.fillSubtle))
            VStack(alignment: .leading, spacing: DS.Space.s6) {
                radio("Keep files as they are", selected: !model.revertFiles) { Task { await model.setRevertFiles(false) } }
                radio("Revert files too", selected: model.revertFiles) { Task { await model.setRevertFiles(true) } }
            }
            Text(model.filesLine).font(.ds(.meta)).foregroundStyle(model.plan?.filesUnavailable != nil && model.revertFiles ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { close(false) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).keyboardShortcut(.cancelAction)
                Button(model.revertFiles && model.plan?.files != nil ? "Rewind and Restore Files" : "Rewind Conversation") {
                    Task { if await model.rewind() { close(true) } }
                }
                .buttonStyle(DSButtonStyle(.destructive, size: .small))
                .disabled(model.plan == nil || model.isPlanning || model.isRewinding)
            }
        }
        .padding(DS.Space.s16)
        .frame(width: 440)
        .task { if model.plan == nil { await model.replan() } }
    }

    func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s8) {
                DSToggleMark(kind: .radio, isOn: selected)
                Text(title).foregroundStyle(SwiftUI.Color.ds.text)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Clone from GitLab…".
public struct GitCloneView: View {
    @Bindable var model: GitCloneModel
    let close: (Bool) -> Void
    @FocusState private var focused: Bool

    public init(model: GitCloneModel, close: @escaping (Bool) -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            Text("Clone from GitLab").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
            if model.instances.isEmpty {
                Text("Add your GitLab instance and token in Settings ▸ GitLab first.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
            }
            if model.instances.count > 1 {
                DSSegmentedPicker(options: model.instances.map { ($0.baseURL, $0.host) }, selection: Binding(
                    get: { model.instance?.baseURL ?? "" }, set: { id in model.instance = model.instances.first { $0.baseURL == id }; model.refresh() }))
            }
            HStack(spacing: DS.Space.s8) {
                PickerSearchGlyph()
                TextField("", text: $model.query, prompt: Text("Search your projects on \(model.instance?.host ?? "GitLab")"))
                    .textFieldStyle(.plain).focused($focused)
                    .onChange(of: model.query) { model.refresh() }
                    .accessibilityLabel("Search GitLab projects")
                if model.isSearching { StatusLabel(.running, showsText: false).accessibilityLabel("Searching") }
            }
            .padding(.horizontal, DS.Space.s8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.fillSubtle))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projects) { project in
                        PickerRow(
                            symbol: "folder", title: project.path,
                            detail: [project.description?.isEmpty == false ? project.description : nil, project.lastActivity.map { "active " + RelativeTime.short($0) + " ago" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            selected: model.selected?.id == project.id, highlighted: false
                        ) { model.selected = project; model.pastedURL = "" }
                    }
                    if model.projects.isEmpty, !model.isSearching {
                        Text(model.query.isEmpty ? "No projects yet." : "No matching project.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s10)
                    }
                }
            }
            .frame(height: 210)
            labelled("Or paste a URL") {
                TextField("", text: $model.pastedURL, prompt: Text("https://\(model.instance?.host ?? "gitlab.example.com")/group/project.git"))
                    .textFieldStyle(DSTextFieldStyle()).onChange(of: model.pastedURL) { model.pastedChanged() }
            }
            labelled("Clone into") { TextField("", text: $model.destination).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Destination folder") }
            Text("The project opens at once; you can write the first prompt while it clones, and sending waits for the files. git uses HTTPS with your GitLab token.")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
            }
            HStack {
                Spacer()
                Button("Cancel") { close(false) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).keyboardShortcut(.cancelAction)
                Button("Clone") { if model.clone() { close(true) } }
                    .buttonStyle(DSButtonStyle(.primary, size: .small, hint: "↩")).keyboardShortcut(.defaultAction).disabled(!model.canClone)
            }
        }
        .font(.ds(.body))
        .padding(DS.Space.s16)
        .frame(width: 520)
        .onAppear {
            focused = true
            if model.projects.isEmpty { model.refresh() }
        }
    }
}

/// "Publish to GitLab…".
public struct GitPublishView: View {
    @Bindable var model: GitPublishModel
    let close: (Bool) -> Void

    public init(model: GitPublishModel, close: @escaping (Bool) -> Void) {
        self.model = model
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s10) {
            Text("Publish to GitLab").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text)
            labelled("Name") { TextField("", text: $model.name).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Project name") }
            labelled("Path") { TextField("", text: $model.path).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Project path") }
            if !model.namespaces.isEmpty {
                labelled("Namespace") {
                    DSSegmentedPicker(options: model.namespaces.prefix(4).map { ($0.id, $0.fullPath) }, selection: Binding(
                        get: { model.namespaceID ?? model.namespaces[0].id }, set: { model.namespaceID = $0 }))
                }
            }
            Text("Creates a private project on \(model.instance?.host ?? "GitLab"), adds it as origin (HTTPS) and pushes the current branch.")
                .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
            }
            HStack {
                Spacer()
                Button("Cancel") { close(false) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).keyboardShortcut(.cancelAction)
                Button(model.isPublishing ? "Publishing…" : "Publish") { Task { if await model.publish() { close(true) } } }
                    .buttonStyle(DSButtonStyle(.primary, size: .small)).keyboardShortcut(.defaultAction).disabled(!model.canPublish)
            }
        }
        .font(.ds(.body))
        .padding(DS.Space.s16)
        .frame(width: 440)
        .task { await model.load() }
    }
}

@MainActor
func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: DS.Space.s10) {
        Text(title).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 96, alignment: .trailing)
        content()
    }
}
