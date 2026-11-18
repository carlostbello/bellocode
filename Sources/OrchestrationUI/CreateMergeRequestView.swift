import AppKit
import BelloCore
import DesignSystem
import Engine
import SwiftUI

/// The inline "New Merge Request" form (no sheet): source branch with push state and Push, target branch, generated
/// and editable title and description, draft, optional assignees and reviewers, and a preview of exactly what will be
/// sent. Create is enabled only when the branch is pushed, the draft is valid and write actions are on.
struct CreateMergeRequestView: View {
    let model: CreateMergeRequestModel
    let cancel: () -> Void

    var body: some View {
        let bindable = Bindable(model)
        VStack(alignment: .leading, spacing: DS.Space.s8) {
            HStack {
                Text("New Merge Request").font(.ds(.title)).foregroundStyle(SwiftUI.Color.ds.text)
                Spacer()
                if model.generating { Text("Asking the thread's model…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3) }
            }
            if case .failed(let text) = model.phase {
                Label(text, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { Task { await model.prepare() } }
                    Spacer()
                    Button("Close") { cancel() }
                }
            } else if model.phase == .loading {
                Text("Checking the branch and the project…").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3)
            } else {
                field("Source") {
                    HStack(spacing: DS.Space.s6) {
                        Text(model.sourceBranch).font(.ds(.codeSmall)).foregroundStyle(SwiftUI.Color.ds.text)
                        if let checkout = model.checkout {
                            if checkout.isPushed {
                                Label("Pushed", systemImage: "checkmark.circle").foregroundStyle(SwiftUI.Color.ds.successText)
                            } else {
                                Label(checkout.upstream == nil ? "Not on the remote" : "\(checkout.ahead) to push", systemImage: "arrow.up.circle")
                                    .foregroundStyle(SwiftUI.Color.ds.warningText)
                                Button(model.pushing ? "Pushing…" : "Push") { Task { await model.push() } }.disabled(model.pushing)
                                    .help("Push with your own git setup (the GitLab token is not used)")
                            }
                        }
                    }
                }
                field("Target") {
                    DSMenuSelect("Target branch", options: model.branchOptions.map { (id: $0, title: $0) }, selection: bindable.target, minWidth: 160)
                }
                field("Title") {
                    TextField("Title", text: bindable.title).textFieldStyle(DSTextFieldStyle()).accessibilityLabel("Merge request title")
                }
                field("Description") {
                    TextEditor(text: bindable.description)
                        .font(.ds(.body))
                        .scrollContentBackground(.hidden)
                        .padding(DS.Space.s4)
                        .frame(minHeight: 90, maxHeight: 180)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.md).fill(SwiftUI.Color.ds.fillSubtle))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(SwiftUI.Color.ds.borderStrong, lineWidth: 1))
                        .accessibilityLabel("Merge request description")
                }
                if !model.proposalSource.isEmpty {
                    Text(model.proposalSource + "; edit freely.").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).padding(.leading, 84)
                }
                field("Options") {
                    HStack(spacing: DS.Space.s12) {
                        Toggle("Draft", isOn: bindable.draft)
                        Toggle("Delete source branch when merged", isOn: bindable.removeSourceBranch)
                    }
                    .font(.ds(.label))
                }
                people("Assignees", query: bindable.assigneeQuery, list: model.assignees, reviewer: false)
                people("Reviewers", query: bindable.reviewerQuery, list: model.reviewers, reviewer: true)
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    Text("Will send").font(.ds(.metaEmph)).foregroundStyle(SwiftUI.Color.ds.text3)
                    Text(model.endpointText).font(.ds(.codeSmall)).foregroundStyle(SwiftUI.Color.ds.text2).textSelection(.enabled)
                    ScrollView {
                        Text(model.mergeDraft.payloadText).font(.ds(.codeSmall)).foregroundStyle(SwiftUI.Color.ds.text2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s6)
                    }
                    .frame(maxHeight: 140)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(SwiftUI.Color.ds.codeFill))
                    .accessibilityLabel("Preview of the request")
                }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DS.Space.s6) {
                    Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                    Button("Open in GitLab") { model.openInGitLab() }.help("Create it on GitLab's own page instead")
                    Spacer()
                    if let blocker = model.blocker, model.phase != .creating {
                        Text(blocker).font(.ds(.meta)).foregroundStyle(SwiftUI.Color.ds.text3).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    Button(model.phase == .creating ? "Creating…" : "Create Merge Request") { Task { await model.create() } }
                        .buttonStyle(DSButtonStyle(.primary, size: .small))
                        .disabled(model.blocker != nil)
                }
            }
        }
        .font(.ds(.label))
        .padding(DS.Space.s10)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(SwiftUI.Color.ds.raised))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(SwiftUI.Color.ds.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New merge request")
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s8) {
            Text(label).font(.ds(.label)).foregroundStyle(SwiftUI.Color.ds.text2).frame(width: 76, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func people(_ label: String, query: Binding<String>, list: [GitLabUserRef], reviewer: Bool) -> some View {
        field(label) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                if !list.isEmpty {
                    HStack(spacing: DS.Space.s4) {
                        ForEach(list) { user in
                            Button {
                                model.remove(user, reviewer: reviewer)
                            } label: {
                                Label("@\(user.username)", systemImage: "xmark")
                            }
                            .buttonStyle(DSButtonStyle(.ghost, size: .small))
                            .help("Remove @\(user.username)")
                        }
                    }
                }
                HStack(spacing: DS.Space.s4) {
                    TextField("Optional: username", text: query).textFieldStyle(DSTextFieldStyle())
                        .onSubmit { Task { await model.addPerson(reviewer: reviewer) } }
                        .accessibilityLabel("Add \(label.lowercased())")
                    Button("Add") { Task { await model.addPerson(reviewer: reviewer) } }
                        .disabled(query.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
