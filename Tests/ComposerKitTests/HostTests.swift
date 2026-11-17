import BelloCore
import Foundation
import Observation
import Testing
import UniformTypeIdentifiers
@testable import ComposerKit

@MainActor
final class FakeComposerHost: ComposerHost {
    let draftKey: String
    var draft = ComposerDraft.empty
    var runState: ComposerRunState = .idle
    var supportsSteer = true
    var supportsAttachments = true
    var outcomes: [ComposerSendOutcome] = []
    var submissions: [ComposerSubmission] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdSends = false
    var stopCalls = 0
    var prompts: [String] = []

    init(_ key: String, draft: ComposerDraft = .empty) {
        draftKey = key
        self.draft = draft
    }

    func loadDraft() -> ComposerDraft { draft }
    func saveDraft(_ draft: ComposerDraft) { self.draft = draft }
    func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome {
        if holdSends { await withCheckedContinuation { gate = $0 } }
        submissions.append(submission)
        return outcomes.isEmpty ? .accepted : outcomes.removeFirst()
    }
    func release() {
        gate?.resume()
        gate = nil
    }
    func stop() async { stopCalls += 1 }
    func recentPrompts() -> [String] { prompts }
    func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation { ComposerObservation {} }
}

/// Stands in for the view: holds a draft value.
@MainActor
final class FakeView {
    var draft = ComposerDraft.empty
    var undoableReplacements = 0

    func bind(_ controller: ComposerController) {
        controller.currentDraft = { [unowned self] in draft }
        controller.applyDraft = { [unowned self] in draft = $0 }
        controller.replaceTextUndoably = { [unowned self] in
            draft.text = $0.text
            draft.tokens = $0.tokens
            undoableReplacements += 1
        }
    }
}

private func settle() async {
    for _ in 0..<5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(10))
}

@MainActor
@Suite struct ComposerControllerTests {
    @Test func sendClearsAtOnceAndRestoresOnFailure() async {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = FakeComposerHost("a")
        host.outcomes = [.failed("offline")]
        host.holdSends = true
        controller.attach(host)
        view.draft = ComposerDraft(text: "fix it", attachments: [.text("log")])
        #expect(controller.submit())
        #expect(view.draft == .empty)
        #expect(host.draft == .empty)
        #expect(controller.pendingSends == 1)
        view.draft = ComposerDraft(text: "more")
        await settle()
        host.release()
        await settle()
        #expect(view.draft.text == "fix it\n\nmore")
        #expect(view.draft.attachments.count == 1)
        #expect(controller.errorMessage == "offline")
        #expect(controller.pendingSends == 0)
        #expect(host.draft.text == "fix it\n\nmore")
    }

    @Test func emptyDraftSendsNothing() {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        controller.attach(FakeComposerHost("a"))
        view.draft = ComposerDraft(text: "  \n")
        #expect(!controller.submit())
    }

    @Test func failureAfterSwitchGoesToItsOwnThread() async {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let a = FakeComposerHost("a")
        let b = FakeComposerHost("b", draft: ComposerDraft(text: "beta"))
        a.outcomes = [.failed("nope")]
        a.holdSends = true
        controller.attach(a)
        view.draft = ComposerDraft(text: "alpha")
        controller.submit()
        controller.attach(b)
        #expect(view.draft.text == "beta")
        await settle()
        a.release()
        await settle()
        #expect(view.draft.text == "beta")
        #expect(a.draft.text == "alpha")
        #expect(controller.errorMessage == nil)
    }

    @Test func switchingSavesPendingDraftImmediately() {
        let controller = ComposerController()
        controller.draftSaveDelay = .seconds(10)
        let view = FakeView()
        view.bind(controller)
        let a = FakeComposerHost("a")
        controller.attach(a)
        view.draft = ComposerDraft(text: "typed", selection: NSRange(location: 2, length: 1))
        controller.draftDidChange()
        #expect(a.draft == .empty)
        controller.attach(FakeComposerHost("b"))
        #expect(a.draft.text == "typed")
        #expect(a.draft.selection == NSRange(location: 2, length: 1))
    }

    @Test func refusesAttachmentsTheHostCannotSend() {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = FakeComposerHost("a")
        host.supportsAttachments = false
        controller.attach(host)
        view.draft = ComposerDraft(text: "see", attachments: [.text("x")])
        #expect(!controller.submit())
        #expect(view.draft.text == "see")
        #expect(controller.errorMessage != nil)
    }

    @Test func deliveryFollowsRunState() async {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = FakeComposerHost("a")
        controller.attach(host)
        #expect(controller.primaryAction(alternate: false, draftIsEmpty: true) == .send(.now))
        host.runState = .running
        #expect(controller.primaryAction(alternate: false, draftIsEmpty: true) == .stop)
        #expect(controller.primaryAction(alternate: false, draftIsEmpty: false) == .send(.queue))
        #expect(controller.primaryAction(alternate: true, draftIsEmpty: false) == .send(.steer))
        view.draft = ComposerDraft(text: "steer this")
        controller.submit(alternate: true)
        await settle()
        #expect(host.submissions.last?.delivery == .steer)
        controller.stop()
        await settle()
        #expect(host.stopCalls == 1)
        host.runState = .stopping
        #expect(controller.primaryAction(alternate: false, draftIsEmpty: true) == .stopping)
    }

    @Test func historyStashesAndRestoresTheDraft() {
        let controller = ComposerController()
        let view = FakeView()
        view.bind(controller)
        let host = FakeComposerHost("a")
        host.prompts = ["old"]
        controller.attach(host)
        view.draft = ComposerDraft(text: "wip", attachments: [.text("keep")])
        #expect(controller.historyPrevious())
        #expect(view.draft.text == "old")
        #expect(view.draft.attachments.count == 1, "history replaces text only")
        #expect(!controller.historyPrevious())
        #expect(controller.historyNext())
        #expect(view.draft.text == "wip")
        #expect(!controller.historyNext())
        #expect(view.undoableReplacements == 2)
    }
}

// MARK: - ThreadModel adapter

@MainActor
@Observable
final class FakeThread: ComposerThreadSource {
    let sessionID = SessionID("ses_1")
    var draft = ""
    var loaded = true
    var isDraftLoaded: Bool { loaded }
    var unknown = false
    var composerDeliveryUnknown: Bool { unknown }
    var isRunning = false
    var isStopping = false
    var composerErrorMessage: String?
    var composerPromptHistory: [String] = ["earlier"]
    @ObservationIgnored var sent: [(String?, PromptDelivery?)] = []
    @ObservationIgnored var sentAttachments: [PromptAttachments] = []
    @ObservationIgnored var commands: [(name: String, arguments: String, attachments: PromptAttachments)] = []
    @ObservationIgnored var nextResult: MessageID? = MessageID("msg_1")
    @ObservationIgnored var stops = 0

    func send(_ text: String?, attachments: PromptAttachments, delivery: PromptDelivery?) async -> MessageID? {
        sent.append((text, delivery))
        sentAttachments.append(attachments)
        if nextResult == nil { composerErrorMessage = "BelloCode is not connected to opencode. Nothing was sent." }
        return nextResult
    }

    func runCommand(_ name: String, arguments: String, attachments: PromptAttachments, delivery: PromptDelivery?) async -> Bool {
        commands.append((name, arguments, attachments))
        return nextResult != nil
    }

    func stop() async { stops += 1 }
    func clearError() { composerErrorMessage = nil }
}

@MainActor
@Suite struct ThreadModelAdapterTests {
    @Test func draftsKeepRichStateWhileTextMatches() {
        let thread = FakeThread()
        let cache = ComposerDraftCache(capacity: 2)
        let host = ThreadModelComposerHost(thread, cache: cache)
        let token = ComposerToken(kind: .file, text: "@a", value: "a")
        let rich = ComposerDraft(text: "see @a", tokens: [PlacedToken(token: token, range: NSRange(location: 4, length: 2))],
                                 selection: NSRange(location: 1, length: 2))
        host.saveDraft(rich)
        #expect(thread.draft == "see @a")
        #expect(host.loadDraft() == rich)
        thread.draft = "changed elsewhere"
        #expect(host.loadDraft() == ComposerDraft(text: "changed elsewhere"))
        #expect(host.draftKey == "ses_1")
        #expect(host.recentPrompts() == ["earlier"])
    }

    @Test func cacheIsBounded() {
        let cache = ComposerDraftCache(capacity: 2)
        for key in ["a", "b", "c"] { cache.store(ComposerDraft(text: key), for: key) }
        #expect(cache.draft(for: "a") == nil)
        #expect(cache.draft(for: "c")?.text == "c")
    }

    @Test func sendMapsDeliveryAndFailures() async {
        let thread = FakeThread()
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        #expect(await host.send(ComposerSubmission(text: "a", tokens: [], attachments: [], delivery: .now)) == .accepted)
        #expect(await host.send(ComposerSubmission(text: "b", tokens: [], attachments: [], delivery: .queue)) == .accepted)
        #expect(await host.send(ComposerSubmission(text: "c", tokens: [], attachments: [], delivery: .steer)) == .accepted)
        #expect(thread.sent.map(\.1) == [nil, .queue, .steer])
        thread.nextResult = nil
        let failed = await host.send(ComposerSubmission(text: "d", tokens: [], attachments: [], delivery: .now))
        #expect(failed == .failed("BelloCode is not connected to opencode. Nothing was sent."))
        #expect(thread.sent.count == 4)
        #expect(host.supportsAttachments)
    }

    @Test func attachmentsAndMentionsBecomePromptInput() async throws {
        let thread = FakeThread()
        let directory = FileManager.default.temporaryDirectory.appending(path: "composer-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttachmentFileStore(directory: directory)
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache(), fileStore: store)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = ComposerAttachment.image(png, type: .png)
        let onDisk = ComposerAttachment.file(at: URL(filePath: "/tmp/notes.md"))
        let text = "Look at @src/a.swift with @explore"
        let file = ComposerToken(kind: .file, text: "@src/a.swift", value: "/repo/src/a.swift")
        let agent = ComposerToken(kind: .agent, text: "@explore", value: "explore")
        let submission = ComposerSubmission(
            text: text,
            tokens: [
                PlacedToken(token: file, range: NSRange(location: 8, length: 12)),
                PlacedToken(token: agent, range: NSRange(location: 26, length: 8)),
            ],
            attachments: [image, onDisk], delivery: .now)
        #expect(await host.send(submission) == .accepted)
        let sent = try #require(thread.sentAttachments.last)
        #expect(sent.files.count == 3)
        #expect(sent.files[0] == PromptAttachments.File(
            uri: "file:///repo/src/a.swift", name: "a.swift", mime: sent.files[0].mime,
            mention: .init(start: 8, end: 20, text: "@src/a.swift")))
        #expect(sent.agents == [.init(name: "explore", mention: .init(start: 26, end: 34, text: "@explore"))])
        // The pasted image was written to the store; the file on disk is sent as it is.
        let written = try #require(URL(string: sent.files[1].uri))
        #expect(written.path.hasPrefix(directory.path))
        #expect(try Data(contentsOf: written) == png)
        #expect(sent.files[1].mime == "image/png")
        #expect(sent.files[2].uri == "file:///tmp/notes.md")
        // A retry writes the same file again (named by attachment ID), not a second one.
        _ = await host.send(submission)
        #expect(thread.sentAttachments.last?.files[1].uri == sent.files[1].uri)
    }

    @Test func leadingCommandTokenRunsTheServerCommand() async {
        let thread = FakeThread()
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        let command = ComposerToken(kind: .command, text: "/review", value: "review")
        let file = ComposerToken(kind: .file, text: "@a.swift", value: "/r/a.swift")
        let submission = ComposerSubmission(
            text: "/review  focus on @a.swift",
            tokens: [
                PlacedToken(token: command, range: NSRange(location: 0, length: 7)),
                PlacedToken(token: file, range: NSRange(location: 18, length: 8)),
            ],
            attachments: [], delivery: .now)
        #expect(await host.send(submission) == .accepted)
        #expect(thread.sent.isEmpty)
        #expect(thread.commands.first?.name == "review")
        #expect(thread.commands.first?.arguments == "focus on @a.swift")
        #expect(thread.commands.first?.attachments.files.first?.mention == .init(start: 9, end: 17, text: "@a.swift"))
    }

    @Test func fileStoreCleanUpIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "composer-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttachmentFileStore(directory: directory, maxAge: .seconds(3600), maxTotalBytes: 10)
        for index in 0..<3 {
            _ = try await store.materialize(.text(String(repeating: "x", count: 6), name: "t\(index).txt"))
        }
        // 18 bytes > 10: the oldest go until the total fits.
        let removed = await store.cleanUp()
        #expect(removed == 2)
        let old = AttachmentFileStore(directory: directory, maxAge: .seconds(1), maxTotalBytes: 1_000)
        #expect(await old.cleanUp(now: Date().addingTimeInterval(10)) == 1)
        #expect(AttachmentFileStore.safeComponent("../a/b") == ".._a_b")
    }

    @Test func runStateAndObservation() async {
        let thread = FakeThread()
        let host = ThreadModelComposerHost(thread, cache: ComposerDraftCache())
        var changes = 0
        let observation = host.observe { changes += 1 }
        #expect(host.runState == .idle)
        thread.isRunning = true
        await settle()
        #expect(host.runState == .running)
        #expect(changes == 1)
        thread.isStopping = true
        await settle()
        #expect(host.runState == .stopping)
        #expect(changes == 2)
        observation.cancel()
        thread.composerErrorMessage = "x"
        await settle()
        #expect(changes == 2)
        #expect(host.errorMessage == "x")
        host.clearError()
        #expect(thread.composerErrorMessage == nil)
        await host.stop()
        #expect(thread.stops == 1)
    }
}
