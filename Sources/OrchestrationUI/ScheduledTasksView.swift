import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// Relative times both ways: "in 4m", "4m ago", "now".
public enum ExtrasTime {
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if abs(seconds) < 60 { return "now" }
        let magnitude = abs(seconds)
        let text: String =
            switch magnitude {
            case ..<3_600: "\(Int(magnitude / 60))m"
            case ..<86_400: "\(Int(magnitude / 3_600))h \(Int(magnitude.truncatingRemainder(dividingBy: 3_600) / 60))m"
            default: "\(Int(magnitude / 86_400))d"
            }
        return seconds > 0 ? "in " + text : text + " ago"
    }

    /// "Tue 09:00" (this week) or "17 Nov 09:00", in the task's zone.
    public static func when(_ date: Date, timeZone: TimeZone, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = date.timeIntervalSince(now) < 6 * 86_400 ? "EEE HH:mm" : "d MMM HH:mm"
        return formatter.string(from: date)
    }
}

/// Words for a task's state in the list.
public enum ScheduleText {
    public static func state(_ task: ScheduledTask, running: Bool, now: Date) -> String {
        if running { return "Running…" }
        if task.approval == .pending { return "Waiting for your approval" }
        if !task.enabled { return task.nextRun == nil && { if case .once = task.rule { true } else { false } }() ? "Done" : "Paused" }
        guard let next = task.nextRun else { return "No next run" }
        return "Next \(ExtrasTime.when(next, timeZone: task.timeZone, now: now)) (\(ExtrasTime.relative(next, now: now)))"
    }

    public static func lastRun(_ task: ScheduledTask, now: Date) -> String? {
        guard let run = task.lastRun else { return nil }
        let missed = run.missed > 0 ? " (\(run.missed) missed)" : ""
        return "\(run.succeeded ? "✓" : run.label.hasPrefix("Skipped") ? "–" : "✕") \(run.label)\(missed) \(ExtrasTime.relative(run.started, now: now))"
    }
}

/// An editable copy of a task (the inline editor; nothing is saved until Save).
public struct ScheduleDraft: Equatable {
    public enum Kind: String, CaseIterable, Identifiable {
        case interval, daily, once
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .interval: "Every…"
            case .daily: "At a time"
            case .once: "Once"
            }
        }
    }

    public var id: String?
    public var name = ""
    public var prompt = ""
    public var kind: Kind = .daily
    public var everyMinutes = 60
    public var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    public var once = Date().addingTimeInterval(3_600)
    public var timeZoneID = TimeZone.current.identifier
    public var directory = ""
    public var threadID: SessionID?
    public var agent = ""
    public var permissionMode: PermissionMode?
    public var catchUp = true
    public var enabled = true

    public init(directory: String) { self.directory = directory }

    public init(_ task: ScheduledTask) {
        id = task.id
        name = task.name
        prompt = task.prompt
        switch task.rule {
        case .interval(let minutes):
            kind = .interval
            everyMinutes = minutes
        case .daily(let hour, let minute, let days):
            kind = .daily
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = task.timeZone
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            weekdays = Set(days.isEmpty ? Array(1...7) : days)
        case .once(let date):
            kind = .once
            once = date
        }
        timeZoneID = task.timeZoneID
        directory = task.directory
        if case .thread(let id) = task.destination { threadID = id }
        agent = task.agent ?? ""
        permissionMode = task.permissionMode
        catchUp = task.catchUp
        enabled = task.enabled
    }

    public var rule: ScheduleRule {
        switch kind {
        case .interval: return .interval(minutes: max(1, everyMinutes))
        case .daily:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            return .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays.count == 7 ? [] : weekdays.sorted())
        case .once: return .once(once)
        }
    }

    public func apply(to task: ScheduledTask?) -> ScheduledTask {
        var result = task ?? ScheduledTask(name: name, prompt: prompt, rule: rule, directory: directory, created: Date())
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.prompt = prompt
        result.rule = rule
        result.timeZoneID = timeZoneID
        result.directory = directory
        result.destination = threadID.map(ScheduleDestination.thread) ?? .newThread
        result.agent = agent.trimmingCharacters(in: .whitespaces).isEmpty ? nil : agent.trimmingCharacters(in: .whitespaces)
        result.permissionMode = permissionMode
        result.catchUp = catchUp
        result.enabled = enabled
        return result
    }
}

/// The Scheduled Tasks pane's state: selection, the inline editor's draft, Undo of the last delete.
@MainActor
@Observable
public final class ScheduledTasksModel {
    public let scheduler: SchedulerService
    public var selection: String?
    public var draft: ScheduleDraft?
    public private(set) var message: String?
    public private(set) var lastDeleted: ScheduledTask?
    /// Project folders to choose from, and threads per project for "Into thread" (title, ID).
    @ObservationIgnored public var projects: () -> [(name: String, directory: String)] = { [] }
    @ObservationIgnored public var threads: (String) -> [(title: String, id: SessionID)] = { _ in [] }
    @ObservationIgnored public var openThread: (SessionID) -> Void = { _ in }
    @ObservationIgnored public var now: () -> Date = Date.init

    public init(scheduler: SchedulerService) {
        self.scheduler = scheduler
    }

    public var tasks: [ScheduledTask] { scheduler.tasks }

    public func select(_ id: String?) {
        selection = id
        draft = id.flatMap(scheduler.task).map(ScheduleDraft.init)
        message = nil
    }

    public func newTask() {
        selection = nil
        var draft = ScheduleDraft(directory: projects().first?.directory ?? "")
        draft.name = "New task"
        self.draft = draft
        message = nil
    }

    public var canSave: Bool {
        guard let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.directory.isEmpty && draft.rule.problem == nil
    }

    public func save() async {
        guard let draft else { return }
        do {
            if let id = draft.id, let existing = scheduler.task(id) {
                try await scheduler.update(draft.apply(to: existing))
                select(id)
            } else {
                let created = try await scheduler.create(draft.apply(to: nil))
                select(created.id)
            }
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func setEnabled(_ id: String, _ enabled: Bool) async {
        do { try await scheduler.setEnabled(id, enabled) } catch { message = ExtrasError.message(error) }
        if selection == id { draft = scheduler.task(id).map(ScheduleDraft.init) }
    }

    public func runNow(_ id: String) async {
        do {
            try await scheduler.runNow(id)
            message = nil
        } catch {
            message = ExtrasError.message(error)
        }
    }

    /// Deletes at once; `undoDelete` restores it.
    public func delete(_ id: String) async {
        do {
            lastDeleted = try await scheduler.delete(id)
            if selection == id { select(nil) }
        } catch {
            message = ExtrasError.message(error)
        }
    }

    public func undoDelete() async {
        guard let task = lastDeleted else { return }
        lastDeleted = nil
        try? await scheduler.restore(task)
        select(task.id)
    }

    /// Approves exactly what the editor shows (the draft loaded from the task): if an agent changed the task since,
    /// nothing is approved.
    public func approve(_ id: String) async {
        guard let existing = scheduler.task(id) else { return }
        let shown = draft.flatMap { $0.id == id ? $0.apply(to: existing).definition : nil } ?? existing.definition
        do {
            try await scheduler.approve(id, digest: shown.digest, always: false)
        } catch {
            message = ExtrasError.message(error)
            if selection == id { draft = scheduler.task(id).map(ScheduleDraft.init) }
        }
    }
}

/// Settings ▸ Scheduled Tasks: list (state, next run, last result with a link to its thread, enable switch) and an
/// inline editor; Run Now, Delete with Undo, the projects where agents may schedule without asking.
public struct ScheduledTasksView: View {
    let model: ScheduledTasksModel

    public init(model: ScheduledTasksModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                list.frame(width: 300)
                SwiftUI.Color.ds.border.frame(height: 1)
                editor.frame(minWidth: 360, maxWidth: .infinity)
            }
            SwiftUI.Color.ds.border.frame(height: 1)
            footer
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .frame(width: 760, height: 520)
        .transaction { $0.animation = nil }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scheduled Tasks").font(.ds(.title))
                Spacer()
                Button {
                    model.newTask()
                } label: {
                    Image(systemName: "plus").font(.system(size: DS.Size.iconPointRow, weight: .medium))
                }
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .help("New scheduled task")
                .accessibilityLabel("New scheduled task")
            }
            .padding(DS.Space.s6)
            if model.tasks.isEmpty {
                Text("No scheduled tasks yet. Click + to add one, or ask an agent (it uses schedule_task; the first one in a project asks for your approval).")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).padding(DS.Space.s6).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                // DS rows (neutral `rowActive` selection, never accent); ↑/↓ move the selection.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.tasks) { task in
                            row(task)
                                .padding(.horizontal, DS.Space.s8)
                                .padding(.vertical, DS.Space.s6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .dsRowBackground(.resolve(hovered: false, selected: false, active: model.selection == task.id), radius: DS.Radius.md)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(task.id) }
                                .accessibilityAddTraits(model.selection == task.id ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                    .padding(DS.Space.s4)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.downArrow) { moveSelection(1) }
            }
            if let deleted = model.lastDeleted {
                HStack {
                    Text("Deleted “\(deleted.name)”.").font(.ds(.meta)).lineLimit(1)
                    Button("Undo") { Task { await model.undoDelete() } }.buttonStyle(DSButtonStyle(.ghost, size: .small)).font(.ds(.meta))
                }
                .padding(DS.Space.s6)
            }
        }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !model.tasks.isEmpty else { return .ignored }
        let index = model.tasks.firstIndex { $0.id == model.selection } ?? -1
        model.select(model.tasks[max(0, min(model.tasks.count - 1, index + delta))].id)
        return .handled
    }

    private func row(_ task: ScheduledTask) -> some View {
        let now = model.now()
        let running = model.scheduler.running.contains(task.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s4) {
                Image(systemName: task.approval == .pending ? "exclamationmark.shield" : task.isActive ? "calendar.badge.clock" : "pause.circle")
                    .foregroundStyle(task.approval == .pending ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.text3)
                    .accessibilityHidden(true)
                Text(task.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 0)
                Toggle("Enabled", isOn: Binding(get: { task.enabled }, set: { value in Task { await model.setEnabled(task.id, value) } }))
                    .toggleStyle(DSToggleStyle(.switch)).labelsHidden()
                    .disabled(task.approval == .pending)
                    .accessibilityLabel(task.enabled ? "Enabled" : "Paused")
            }
            Text(task.summary + (task.createdBy != nil ? " · by an agent" : "")).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1)
            Text(ScheduleText.state(task, running: running, now: now)).font(.ds(.meta))
                .foregroundStyle(task.approval == .pending ? SwiftUI.Color.ds.warningText : SwiftUI.Color.ds.text3)
            if let last = ScheduleText.lastRun(task, now: now) {
                HStack(spacing: DS.Space.s4) {
                    Text(last).font(.ds(.meta)).foregroundStyle(task.lastRun?.succeeded == false ? SwiftUI.Color.ds.dangerText : SwiftUI.Color.ds.text3).lineLimit(1)
                    if let thread = task.lastRun?.sessionID {
                        Button("Open Thread") { model.openThread(thread) }.buttonStyle(DSButtonStyle(.ghost, size: .small)).font(.ds(.meta))
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Run Now") { Task { await model.runNow(task.id) } }.disabled(!task.isApprovedAsDefined)
            Button(task.enabled ? "Pause" : "Resume") { Task { await model.setEnabled(task.id, !task.enabled) } }
            SwiftUI.Color.ds.border.frame(height: 1)
            Button("Delete") { Task { await model.delete(task.id) } }
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let draft = model.draft {
            let binding = Binding<ScheduleDraft>(get: { model.draft ?? draft }, set: { model.draft = $0 })
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s8) {
                    EditorRow("Name") {
                        TextField("", text: binding.name, prompt: Text("Morning triage")).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Name")
                    }
                    EditorRow("Prompt", alignment: .top) {
                        TextEditor(text: binding.prompt)
                            .font(.ds(.body))
                            .frame(height: 84)
                            .scrollContentBackground(.hidden)
                            .padding(DS.Space.s4)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.canvas))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.borderStrong))
                            .accessibilityLabel("Prompt")
                    }
                    EditorRow("Runs") {
                        DSSegmentedPicker(options: ScheduleDraft.Kind.allCases.map { (id: $0, title: $0.title) }, selection: binding.kind).fixedSize()
                    }
                    switch draft.kind {
                    case .interval:
                        EditorRow("Every") {
                            DSStepper(
                                "Every", value: binding.everyMinutes, in: 1...44_640, step: draft.everyMinutes < 60 ? 5 : 30,
                                format: { "\($0) minutes" })
                        }
                    case .daily:
                        EditorRow("Time") {
                            // Native time field: per-component keyboard entry, locale and VoiceOver (no DS date control).
                            DatePicker("Time", selection: binding.time, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
                        }
                        EditorRow("Days") {
                            HStack(spacing: 2) {
                                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                    let symbols = Calendar(identifier: .gregorian).veryShortWeekdaySymbols
                                    let isOn = draft.weekdays.contains(day)
                                    Button(symbols[day - 1]) {
                                        var days = model.draft?.weekdays ?? []
                                        if isOn { days.remove(day) } else { days.insert(day) }
                                        model.draft?.weekdays = days
                                    }
                                    .buttonStyle(DSButtonStyle(isOn ? .outline : .ghost, size: .small, isSelected: isOn))
                                    .accessibilityAddTraits(isOn ? .isSelected : [])
                                    .accessibilityLabel(Calendar(identifier: .gregorian).weekdaySymbols[day - 1])
                                }
                            }
                        }
                    case .once:
                        EditorRow("At") {
                            DatePicker("At", selection: binding.once).labelsHidden().fixedSize()
                        }
                    }
                    EditorRow("Time zone") {
                        TextField("", text: binding.timeZoneID).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Time zone")
                    }
                    EditorRow("Project") {
                        DSMenuSelect("Project", options: model.projects().map { ($0.directory, $0.name) }, selection: binding.directory)
                    }
                    EditorRow("Each run") {
                        DSMenuSelect(
                            "Each run",
                            options: [(SessionID?.none, "Starts a new thread")]
                                + model.threads(draft.directory).map { (SessionID?.some($0.id), "Messages “\($0.title)”") },
                            selection: binding.threadID)
                    }
                    EditorRow("Agent") {
                        TextField("", text: binding.agent, prompt: Text("build (default)")).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Agent")
                    }
                    EditorRow("Permissions") {
                        DSMenuSelect(
                            "Permissions",
                            options: [(PermissionMode?.none, "Project default"), (PermissionMode?.some(.ask), "Ask"),
                                      (PermissionMode?.some(.autoEdit), "Auto-edit"), (PermissionMode?.some(.fullAccess), "Full access")],
                            selection: binding.permissionMode)
                    }
                    EditorRow("") {
                        VStack(alignment: .leading, spacing: DS.Space.s6) {
                            Toggle("If missed while BelloCode was quit, run once at launch", isOn: binding.catchUp).toggleStyle(DSToggleStyle(.checkbox))
                            Toggle("Enabled", isOn: binding.enabled).toggleStyle(DSToggleStyle(.checkbox))
                        }
                    }
                    if let problem = draft.rule.problem {
                        EditorRow("") {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                        }
                    }
                    if let message = model.message {
                        EditorRow("") {
                            Label(message, systemImage: "exclamationmark.triangle").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: DS.Space.s6) {
                        if let id = draft.id {
                            Button("Delete") { Task { await model.delete(id) } }.help("Delete this task (Undo is offered)")
                                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                            Button("Run Now") { Task { await model.runNow(id) } }
                                .buttonStyle(DSButtonStyle(.outline, size: .small))
                                .disabled(model.scheduler.task(id)?.isApprovedAsDefined != true || model.scheduler.running.contains(id))
                            if model.scheduler.task(id)?.approval == .pending {
                                Button("Approve") { Task { await model.approve(id) } }.help("Allow this agent-created task to run")
                                    .buttonStyle(DSButtonStyle(.outline, size: .small))
                            }
                        }
                        Spacer()
                        Button("Revert") { model.select(draft.id) }.disabled(draft.id == nil).buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                        Button("Save") { Task { await model.save() } }.keyboardShortcut("s", modifiers: .command)
                            .buttonStyle(DSButtonStyle(.primary, size: .small, hint: "⌘S"))
                            .disabled(!model.canSave)
                    }
                    .padding(.top, DS.Space.s4)
                }
                .padding(DS.Space.s12)
            }
        } else {
            VStack(spacing: DS.Space.s6) {
                Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(SwiftUI.Color.ds.text4).accessibilityHidden(true)
                Text("Select a task to edit it, or click + to add one.").foregroundStyle(SwiftUI.Color.ds.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Tasks run while BelloCode is open, even with no window (the menu-bar item shows the next run). While it is quit nothing runs; at the next launch an overdue task runs once if “run once at launch” is on, otherwise the run is recorded as skipped. Never a burst.")
                .fixedSize(horizontal: false, vertical: true)
            if !model.scheduler.grantedProjects.isEmpty {
                HStack(spacing: DS.Space.s6) {
                    Text("Agents may schedule without asking in:")
                    ForEach(model.scheduler.grantedProjects.sorted(), id: \.self) { directory in
                        Button("\((directory as NSString).lastPathComponent) ✕") {
                            Task { try? await model.scheduler.setProjectGrant(directory, false) }
                        }
                        .help("Revoke: agents in \(directory) will ask again")
                    }
                }
            }
            if let error = model.scheduler.lastError { Text(error).foregroundStyle(SwiftUI.Color.ds.dangerText) }
        }
        .font(.ds(.meta))
        .foregroundStyle(SwiftUI.Color.ds.text3)
        .padding(DS.Space.s6)
    }
}

/// Settings ▸ Secrets: labels of secrets agents asked for (never values), last use, Delete (confirmed: it cannot be
/// undone), and the hosts HTML visuals may load from.
public struct SecretsSettingsView: View {
    let secrets: SecretService
    let visuals: VisualService
    let confirmDelete: (StoredSecretLabel) -> Bool

    public init(secrets: SecretService, visuals: VisualService, confirmDelete: @escaping (StoredSecretLabel) -> Bool) {
        self.secrets = secrets
        self.visuals = visuals
        self.confirmDelete = confirmDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            Text("Secrets agents asked for are kept in your Keychain. Agents only ever get one-use references or one-read files; values are never shown, logged or sent to a model.")
                .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3).fixedSize(horizontal: false, vertical: true)
            if secrets.labels.isEmpty {
                Text("No saved secrets.").foregroundStyle(SwiftUI.Color.ds.text3)
            } else {
                VStack(spacing: 0) {
                    ForEach(secrets.labels) { label in
                        HStack {
                            Image(systemName: "key.fill").foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                Text(label.label)
                                Text("Saved \(label.created.formatted(date: .abbreviated, time: .shortened))"
                                    + (label.lastUsed.map { " · used \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                    .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                            }
                            Spacer()
                            Button("Delete…") {
                                if confirmDelete(label) { Task { await secrets.delete(account: label.account) } }
                            }
                            .accessibilityLabel("Delete \(label.label)")
                        }
                        .padding(.vertical, DS.Space.s4)
                        SwiftUI.Color.ds.border.frame(height: 1)
                    }
                }
            }
            if let error = secrets.lastError { Text(error).foregroundStyle(SwiftUI.Color.ds.dangerText) }
            SwiftUI.Color.ds.border.frame(height: 1)
            Text("Network hosts HTML visuals may load from").font(.ds(.title))
            if visuals.networkGrants.isEmpty {
                Text("None. Visuals load nothing from the network unless you allow a host.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
            } else {
                ForEach(visuals.networkGrants, id: \.self) { host in
                    HStack {
                        Text(host).font(.body.monospaced())
                        Spacer()
                        Button("Revoke") { Task { await visuals.revokeNetwork(host) } }
                    }
                }
            }
        }
        .buttonStyle(DSButtonStyle(.outline))
        .toggleStyle(DSToggleStyle(.checkbox))
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
    }
}

/// One editor row: a right-aligned `label text2` caption column (88 pt) and the control (the DS form layout; no stock
/// `Form`).
private struct EditorRow<Content: View>: View {
    let title: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder let content: Content

    init(_ title: String, alignment: VerticalAlignment = .center, @ViewBuilder content: () -> Content) {
        self.title = title
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: DS.Space.s10) {
            Text(title).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2)
                .frame(width: 88, alignment: .trailing)
                .padding(.top, alignment == .top ? DS.Space.s6 : 0)
                .accessibilityHidden(true)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
