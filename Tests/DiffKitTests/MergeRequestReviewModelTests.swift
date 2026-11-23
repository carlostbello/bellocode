import AppKit
import BelloCore
import Engine
import Foundation
import Testing

@testable import DiffKit

/// The review screen's model against the fake GitLab: threads become inline annotations at their lines (outdated at
/// the file), actions are gated by the write switch, a selection comment becomes a draft, Submit asks first and
/// sends, a moved MR sends nothing and shows the new version, and "Add to Agent Context" quotes untrusted text.
@MainActor @Suite(.timeLimit(.minutes(3)), .serialized) struct MergeRequestReviewModelTests {
    static let instance = GitLabInstance(baseURL: "https://code.corp.test")!
    static let ref = MergeRequestRef(instance: instance.baseURL, projectPath: "platform/rocket", iid: 7)
    static let diff = "@@ -1,3 +1,4 @@\n import Foundation\n-let a = 1\n+let a = 2\n+let b = 3\n func f() {}\n"
    static let v1 = FakeGitLabServer.Version(id: 1, base: "base1", start: "start1", head: "head1", diffs: [("A.swift", "A.swift", "@@ -1,2 +1,2 @@\n import Foundation\n-let a = 1\n+let a = 0\n")])
    static let v2 = FakeGitLabServer.Version(id: 2, base: "base1", start: "start1", head: "head2", diffs: [("A.swift", "A.swift", diff)])

    func make(writes: Bool = true, vault: InMemorySecretVault = InMemorySecretVault()) async throws -> (MergeRequestReviewModel, FakeGitLabServer) {
        let server = FakeGitLabServer(instance: Self.instance, token: "glpat-test-token-0000000000")
        var project = FakeGitLabServer.Project(id: 3, path: "platform/rocket")
        var mr = FakeGitLabServer.MR(iid: 7, title: "Parser", source: "feat/parser")
        mr.versions = [Self.v1, Self.v2]
        mr.sha = "head2"
        func position(_ v: FakeGitLabServer.Version, new: Int) -> FakeGitLabServer.Position {
            FakeGitLabServer.Position(base: v.base, start: v.start, head: v.head, oldPath: "A.swift", newPath: "A.swift", newLine: new)
        }
        var current = FakeGitLabServer.Note(id: 1, author: "mara", body: "Why b?")
        current.diffPosition = position(Self.v2, new: 3)
        var old = FakeGitLabServer.Note(id: 2, author: "lee", body: "Zero?")
        old.diffPosition = position(Self.v1, new: 2)
        mr.discussions = [.init(id: "cur", notes: [current]), .init(id: "old", notes: [old]), .init(id: "gen", notes: [FakeGitLabServer.Note(id: 3, author: "lee", body: "Nice", resolvable: false)])]
        project.mrs[7] = mr
        server.put(project)
        try vault.store(account: Self.instance.baseURL, label: "t", value: SecretValue("glpat-test-token-0000000000"))
        let store = try ProjectionStore(location: .inMemory)
        let service = MergeRequestService(store: store, clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)), transport: server, tokens: vault, autoPoll: false)
        await service.start()
        _ = try await service.saveInstance(baseURL: Self.instance.baseURL, token: nil)
        if writes { await service.setSettings(GitLabInstanceSettings(writesEnabled: true), for: Self.instance.baseURL) }
        let model = MergeRequestReviewModel(ref: Self.ref, service: MergeRequestReviewService(mergeRequests: service, store: store))
        model.now = { Date(timeIntervalSince1970: 1_800_000_000) }
        await model.load()
        return (model, server)
    }

    @Test func threadsBecomeAnnotationsAtTheirLines() async throws {
        let (model, _) = try await make()
        #expect(model.versionLine.hasPrefix("Version 2 of 2 · head head2"))
        #expect(model.diffFiles.map(\.path) == ["A.swift"])
        let annotations = Dictionary(uniqueKeysWithValues: model.annotations.map { ($0.id, $0) })
        #expect(annotations["cur"]?.placement == .line(path: "A.swift", side: .new, line: 3))
        #expect(annotations["cur"]?.state.primary == .unresolved)
        #expect(annotations["old"]?.placement == .file(path: "A.swift") && annotations["old"]?.state.outdated == true)
        #expect(annotations["old"]?.note?.hasPrefix("Outdated") == true)
        #expect(annotations["gen"] == nil && model.elsewhere == 1, "general comments are listed in the panel")
        let actions = model.actions(for: try #require(annotations["cur"])).map(\.id)
        #expect(actions == ["reply", "resolve", "agent", "open"])
    }

    @Test func writesOffDisablesSendingButKeepsDrafting() async throws {
        let (model, server) = try await make(writes: false)
        let thread = try #require(model.annotations.first { $0.id == "cur" })
        #expect(model.actions(for: thread).first { $0.id == "resolve" }?.isEnabled == false)
        await model.comment(DiffReviewComment(path: "A.swift", side: .new, startLine: 2, endLine: 3, quoted: "", text: "Split these."))
        #expect(model.drafts.count == 1 && !model.isError)
        let draft = try #require(model.annotations.first { $0.state.primary == .draft })
        #expect(draft.placement == .line(path: "A.swift", side: .new, line: 3) && draft.note == "Lines 2–3")
        #expect(model.actions(for: draft).first { $0.id == "send" }?.isEnabled == false)
        #expect(server.requests.allSatisfy { $0.method == "GET" })
    }

    @Test func submitAsksAndSendsAndAMovedRequestRefreshesInstead() async throws {
        let (model, server) = try await make()
        let thread = try #require(model.annotations.first { $0.id == "cur" })
        await model.reply(to: thread, text: "Because.", resolve: true)
        var asked: [String] = []
        model.confirm = { title, detail, _ in
            asked.append(title + " " + detail)
            return false
        }
        await model.submit()
        #expect(asked.count == 1 && asked[0].contains("1 comment") && asked[0].contains("as one review"))
        #expect(server.requests.allSatisfy { $0.method == "GET" }, "declined: nothing sent")
        // The MR moves before the person confirms again.
        let v3 = FakeGitLabServer.Version(id: 3, base: "base1", start: "start1", head: "head3", diffs: Self.v2.diffs)
        server.editMR("platform/rocket", 7) {
            $0.versions.append(v3)
            $0.sha = "head3"
        }
        model.confirm = { _, _, _ in true }
        await model.submit()
        #expect(model.isError && model.message?.contains("head2") == true && model.message?.contains("head3") == true)
        #expect(server.requests.allSatisfy { $0.method == "GET" }, "moved: nothing sent")
        #expect(model.versionLine.contains("head3"), "the new version is shown")
        await model.submit()
        #expect(!model.isError && model.message?.contains("one review") == true, "\(model.message ?? "")")
        #expect(model.drafts.isEmpty)
    }

    @Test func addToAgentContextQuotesTheThread() async throws {
        let (model, _) = try await make()
        var inserted: [String] = []
        model.composerTarget = { ComposerTarget { inserted.append($0); return true } }
        let thread = try #require(model.annotations.first { $0.id == "cur" })
        await model.perform(DiffAnnotationAction(id: "agent", title: ""), on: thread)
        #expect(inserted.count == 1 && inserted[0].contains(UntrustedText.beginMarker) && inserted[0].contains("A.swift:3"))
        // AV10: the composer the action started with is no longer shown when the text is ready: nothing is inserted
        // anywhere, and the person is told.
        model.composerTarget = { ComposerTarget { _ in false } }
        await model.perform(DiffAnnotationAction(id: "agent", title: ""), on: thread)
        #expect(inserted.count == 1)
        #expect(model.isError && model.message == ComposerTarget.movedMessage)
        // Discard and Undo of a draft.
        await model.comment(DiffReviewComment(path: "A.swift", side: .new, startLine: 1, endLine: 1, quoted: "", text: "Hm."))
        let draft = try #require(model.annotations.first { $0.state.primary == .draft })
        await model.perform(DiffAnnotationAction(id: "discard", title: ""), on: draft)
        #expect(model.drafts.isEmpty)
        await model.undoDiscard()
        #expect(model.drafts.count == 1)
    }

    /// AV07: when the instance's token cannot be read to redact the notes, nothing goes to the composer.
    @Test func addToAgentContextNeedsTheTokenToRedactWith() async throws {
        let vault = InMemorySecretVault()
        let (model, _) = try await make(vault: vault)
        try vault.delete(account: Self.instance.baseURL)
        var inserted: [String] = []
        model.composerTarget = { ComposerTarget { inserted.append($0); return true } }
        let thread = try #require(model.annotations.first { $0.id == "cur" })
        await model.perform(DiffAnnotationAction(id: "agent", title: ""), on: thread)
        #expect(inserted.isEmpty)
        #expect(model.isError && model.message?.contains("Keychain") == true, "\(model.message ?? "")")
    }
}
