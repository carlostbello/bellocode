import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

// GitLab 2 views in the Merge Requests tab (docs/features/gitlab.md): the project's issues and Start Thread, the
// person's to-dos, the approval explanation, Code Owners and dependent MRs. Text from GitLab is shown as data (no
// Markdown rendering, no links followed); status is a glyph plus a word.

/// Issues of the displayed thread's project: Assigned to me / Mentioned / All open, search, bounded paging, and the
/// selected issue's text with Start Thread, Link to This Thread and related merge requests.
struct IssuesView: View {
    let model: MergeRequestPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            SwiftUI.Color.ds.border.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s6) {
                    if let problem = model.issueProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail = model.issueDetail { IssueDetailView(model: model, issue: detail) }
                    list
                    messages
                }
                .padding(DS.Space.s12)
            }
        }
        .task(id: model.issueFilter) { await model.loadIssues() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            HStack(spacing: DS.Space.s6) {
                Text(model.issueProject.map { "Issues · \($0.projectPath)" } ?? "Issues").font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isLoadingIssues { Text("Updating…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
                Button {
                    Task { await model.loadIssues() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .help("Read the issues again")
            }
            DSSegmentedPicker(options: IssueFilter.allCases.map { ($0, $0.title) }, selection: Bindable(model).issueFilter)
                .accessibilityLabel("Which issues")
            TextField("Search issues", text: Bindable(model).issueSearch)
                .textFieldStyle(DSTextFieldStyle())
                .onSubmit { Task { await model.loadIssues() } }
                .accessibilityLabel("Search issues; Return searches")
        }
        .padding(.horizontal, DS.Space.s12)
        .padding(.vertical, DS.Space.s8)
    }

    @ViewBuilder
    private var list: some View {
        if let list = model.issueList {
            if list.issues.isEmpty {
                Text(model.issueFilter == .mentioned ? "No pending mentions on issues of this project." : "No open issues match.")
                    .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            ForEach(list.issues) { issue in IssueRow(model: model, issue: issue, selected: model.selectedIssue == issue.webURL) }
            HStack(spacing: DS.Space.s6) {
                Text("\(list.issues.count) shown · updated \(ExtrasTime.relative(list.loaded, now: model.now()))").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                Spacer()
                if list.nextPage != nil {
                    Button("Load More") { Task { await model.loadIssues(more: true) } }.disabled(model.isLoadingIssues)
                } else if list.bounded {
                    Text("More on GitLab (BelloCode lists \(GitLabProvider.issuePageSize * GitLabProvider.issueMaxPages)); search to narrow.")
                        .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                }
            }
        } else if model.issueProblem == nil {
            Text("Reading issues…").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.successText).fixedSize(horizontal: false, vertical: true)
        }
        if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct IssueRow: View {
    let model: MergeRequestPanelModel
    let issue: GitLabIssue
    let selected: Bool

    var body: some View {
        Button {
            Task { await model.selectIssue(issue) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Text("#\(issue.iid)").font(.ds(.label)).monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                    Text(issue.title).font(.ds(.body)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(2)
                    Spacer(minLength: 0)
                }
                Text(subtitle).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, DS.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(selected ? SwiftUI.Color.ds.rowActive : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Issue \(issue.iid): \(issue.title). \(subtitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Start Thread…") { model.startThread(issue) }
            Button("Link to This Thread") { Task { await model.linkIssue(issue) } }.disabled(model.threadID == nil)
            Button("Open in GitLab") { if let url = URL(string: issue.webURL) { model.openURL(url, false) } }
        }
    }

    private var subtitle: String {
        var parts = [issue.stateLabel]
        if !issue.assignees.isEmpty { parts.append(issue.assignees.map { "@\($0)" }.joined(separator: ", ")) }
        if !issue.labels.isEmpty { parts.append(issue.labels.prefix(3).joined(separator: ", ")) }
        if let updated = issue.updated { parts.append("updated \(ExtrasTime.relative(updated, now: Date()))") }
        return parts.joined(separator: " · ")
    }
}

/// The selected issue: its text as data (selectable, never rendered or followed), Start Thread with the whole text
/// or the selected part, Link to This Thread, related merge requests.
struct IssueDetailView: View {
    let model: MergeRequestPanelModel
    let issue: GitLabIssue

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s6) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(issue.iid) \(issue.title)").font(.ds(.bodyEmph)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(3)
                Spacer(minLength: 0)
                DSPillView(issue.stateLabel, tone: issue.state == "opened" ? .info : .neutral, symbolName: issue.state == "opened" ? "circle" : "checkmark.circle")
            }
            if let description = issue.description {
                ScrollView {
                    Text(description.isEmpty ? "(no description)" : description)
                        .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(DS.Space.s6)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(SwiftUI.Color.ds.codeFill))
                .accessibilityLabel("Issue text from GitLab")
                if issue.descriptionTruncated { Text("The text is longer on GitLab; the start is shown and quoted.").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
            } else {
                Text("Reading the issue…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
            }
            HStack(spacing: DS.Space.s6) {
                Button("Start Thread…") { model.startThread(issue) }
                    .buttonStyle(DSButtonStyle(.primary, size: .small))
                    .help("A new thread in this project with the issue linked and its text quoted as untrusted context; choose its branch and workspace before sending")
                Button("Link to This Thread") { Task { await model.linkIssue(issue) } }.disabled(model.threadID == nil)
                Spacer()
                Button("Open in GitLab") { if let url = URL(string: issue.webURL) { model.openURL(url, false) } }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            }
            if let related = model.work?.relatedMergeRequests[issue.webURL] {
                SectionTitle(title: "Related merge requests", trailing: related.isEmpty ? "none" : "\(related.count)")
                ForEach(related) { mr in RelatedMergeRequestRow(model: model, mr: mr) }
            }
        }
        .padding(DS.Space.s10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.raised))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
    }
}

struct RelatedMergeRequestRow: View {
    let model: MergeRequestPanelModel
    let mr: RelatedMergeRequest

    var body: some View {
        Button {
            if let url = URL(string: mr.webURL) { model.openURL(url, true) }
        } label: {
            HStack(spacing: DS.Space.s6) {
                Image(systemName: mr.state == "merged" ? "arrow.triangle.merge" : mr.state == "closed" ? "xmark.circle" : "arrow.triangle.pull")
                    .foregroundStyle(SwiftUI.Color.ds.text3).accessibilityHidden(true)
                Text("!\(mr.iid)").monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                Text(mr.title).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                Text(mr.state.capitalized).foregroundStyle(SwiftUI.Color.ds.text3)
                Spacer(minLength: 0)
            }
            .font(.ds(.meta))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(mr.reference) in BelloCode's browser")
        .accessibilityLabel("Merge request \(mr.iid): \(mr.title), \(mr.state)")
    }
}

/// The person's pending GitLab to-dos across instances: compact rows (action in words, target, project, author, age),
/// Open (a linked MR opens in place), Mark Done (needs write actions on). No notifications: to-dos are the person's
/// own GitLab work, not a blocked agent (docs/features/navigation.md keeps notifications for Needs You).
struct TodosView: View {
    let model: MergeRequestPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s6) {
                Text("To-dos").font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text)
                Text("\(model.todos.count)").font(.ds(.meta)).monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                Spacer()
                Button {
                    Task { await model.loadTodos(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(DSButtonStyle(.ghost, size: .small, isMuted: true))
                .help("Read the to-dos again")
            }
            .padding(.horizontal, DS.Space.s12)
            .padding(.vertical, DS.Space.s8)
            SwiftUI.Color.ds.border.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.work.map { Array($0.todoProblems) } ?? [], id: \.key) { instance, problem in
                        Label("\(GitLabInstance(baseURL: instance)?.host ?? instance): \(problem)", systemImage: "exclamationmark.triangle")
                            .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.warningText).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.todos.isEmpty, model.work?.todoLists.isEmpty == false {
                        Text("Nothing to do on GitLab.").font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                    } else if model.work?.todoLists.isEmpty != false, model.work?.todoProblems.isEmpty != false {
                        Text(model.service.instances.isEmpty ? "Connect GitLab in Settings ▸ GitLab to see your to-dos." : "Reading to-dos…")
                            .font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text3)
                    }
                    ForEach(model.todos, id: \.todo.id) { entry in TodoRow(model: model, instance: entry.instance, todo: entry.todo) }
                    if model.work?.todoLists.values.contains(where: \.truncated) == true {
                        Text("More to-dos on GitLab (BelloCode lists the newest 100).").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.successText).fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.s12)
            }
        }
        .task { await model.loadTodos() }
    }
}

struct TodoRow: View {
    let model: MergeRequestPanelModel
    let instance: String
    let todo: GitLabTodo

    var body: some View {
        let selected = model.selectedTodo == todo.id
        HStack(alignment: .top, spacing: DS.Space.s8) {
            Image(systemName: symbol).foregroundStyle(tone).frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.s4) {
                    Text(todo.actionLabel).font(.ds(.labelEmph)).foregroundStyle(tone)
                    Text(todo.targetLabel).font(.ds(.label)).monospacedDigit().foregroundStyle(SwiftUI.Color.ds.text3)
                    Text(todo.targetTitle).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text).lineLimit(1)
                }
                Text([todo.projectPath, todo.author.isEmpty ? nil : "@\(todo.author)", todo.created.map { ExtrasTime.relative($0, now: model.now()) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Open") { model.openTodo(todo) }.buttonStyle(DSButtonStyle(.ghost, size: .small))
            Button("Done") { Task { await model.markDone(todo, instance: instance) } }
                .buttonStyle(DSButtonStyle(.ghost, size: .small))
                .disabled(!model.service.settings(for: instance).writesEnabled)
                .help(model.service.settings(for: instance).writesEnabled ? "Mark done on GitLab" : "Write actions are off for this instance (Settings ▸ GitLab)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, DS.Space.s6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(selected ? SwiftUI.Color.ds.rowActive : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTodo = todo.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(todo.actionLabel): \(todo.targetLabel) \(todo.targetTitle), \(todo.projectPath ?? "")")
        .accessibilityAction(named: "Open") { model.openTodo(todo) }
        .accessibilityAction(named: "Mark Done") { Task { await model.markDone(todo, instance: instance) } }
    }

    private var symbol: String {
        switch todo.action {
        case "build_failed", "unmergeable": "xmark.octagon"
        case "approval_required", "review_requested": "checkmark.seal"
        case "mentioned", "directly_addressed": "at"
        case "assigned": "person.crop.circle"
        default: "checklist"
        }
    }

    private var tone: SwiftUI.Color {
        switch todo.action {
        case "build_failed", "unmergeable": SwiftUI.Color.ds.dangerText
        case "approval_required", "review_requested", "assigned": SwiftUI.Color.ds.warningText
        default: SwiftUI.Color.ds.infoText
        }
    }
}

/// Required versus optional rules, who can approve, hidden groups, reset on push and GitLab's own merge status, as
/// reported by the instance (never a prediction).
struct ApprovalExplanationView: View {
    let explanation: ApprovalExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(explanation.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                    Image(systemName: symbol(line.tone)).foregroundStyle(color(line.tone)).frame(width: 12).accessibilityHidden(true)
                    Text(line.label).foregroundStyle(SwiftUI.Color.ds.text3).frame(width: 84, alignment: .leading)
                    Text(line.text).foregroundStyle(SwiftUI.Color.ds.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func symbol(_ tone: ApprovalExplanation.Tone) -> String {
        switch tone {
        case .done: "checkmark.circle"
        case .waiting: "circle.dashed"
        case .info: "info.circle"
        case .warning: "eye.slash"
        }
    }

    private func color(_ tone: ApprovalExplanation.Tone) -> SwiftUI.Color {
        switch tone {
        case .done: SwiftUI.Color.ds.successText
        case .waiting: SwiftUI.Color.ds.warningText
        case .info: SwiftUI.Color.ds.text3
        case .warning: SwiftUI.Color.ds.warningText
        }
    }
}

/// Code Owners of the changed files, from the repository's CODEOWNERS (read through git).
struct CodeOwnersView: View {
    let summary: CodeOwnersSummary?
    let note: String?

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 3) {
                SectionTitle(title: "Code Owners", trailing: "\(summary.file)\(summary.revision.isEmpty ? "" : " at \(summary.revision)")")
                ForEach(summary.bySection, id: \.section) { section in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s6) {
                        Text(section.section == CodeOwnersFile.defaultSection ? "Default" : section.section).foregroundStyle(SwiftUI.Color.ds.text3)
                            .frame(width: 84, alignment: .leading).lineLimit(1)
                        Text(section.owners.joined(separator: ", ") + " · \(section.files) file\(section.files == 1 ? "" : "s")" + (section.optional ? " · optional" : ""))
                            .foregroundStyle(SwiftUI.Color.ds.text).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
                if summary.unowned > 0 { Text("\(summary.unowned) changed file\(summary.unowned == 1 ? " has" : "s have") no owner.").foregroundStyle(SwiftUI.Color.ds.text3) }
                Text("From the repository's file; GitLab's approval rules above decide what is required.").foregroundStyle(SwiftUI.Color.ds.text4)
            }
        } else {
            // No CODEOWNERS file (or no checkout): nothing is shown. `note` stays available to tests and tooltips.
            EmptyView().help(note ?? "")
        }
    }
}

/// Blockers and dependants (GitLab's dependencies on Premium+, else branch relationships): navigation only.
struct DependenciesSection: View {
    let model: MergeRequestPanelModel
    let snapshot: MergeRequestSnapshot

    var body: some View {
        // Free instances: only branch relationships, and only when there are some (nothing about the missing feature).
        if let dependencies = model.work?.dependencies[snapshot.ref.url], isGitLab(dependencies) || !(dependencies.blockedBy.isEmpty && dependencies.blocks.isEmpty) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                switch dependencies.source {
                case .gitLab: SectionTitle(title: "Dependencies", trailing: "GitLab")
                case .branches: SectionTitle(title: "Related by branch", trailing: "not enforced")
                }
                if dependencies.blockedBy.isEmpty && dependencies.blocks.isEmpty {
                    Text("None.").foregroundStyle(SwiftUI.Color.ds.text3)
                }
                if !dependencies.blockedBy.isEmpty {
                    Text(isGitLab(dependencies) ? "Blocked by (merge these first)" : "Targets the branch of").foregroundStyle(SwiftUI.Color.ds.text2)
                    ForEach(dependencies.blockedBy) { mr in RelatedMergeRequestRow(model: model, mr: mr) }
                }
                if !dependencies.blocks.isEmpty {
                    Text(isGitLab(dependencies) ? "Blocks" : "Merge requests into this branch").foregroundStyle(SwiftUI.Color.ds.text2)
                    ForEach(dependencies.blocks) { mr in RelatedMergeRequestRow(model: model, mr: mr) }
                }
                if dependencies.blocksUnknown { Text("Which merge requests wait for this one is not reported by this instance.").foregroundStyle(SwiftUI.Color.ds.text3) }
            }
            .font(.ds(.meta))
        }
    }

    private func isGitLab(_ dependencies: MergeRequestDependencies) -> Bool { if case .gitLab = dependencies.source { true } else { false } }
}
