import BelloCore
import ComposerKit
import Engine
import Foundation
import Observation
import Testing

@testable import BelloCodeApp

/// A real `ThreadModel` behind a gate: `send` waits at the gate before dispatching, standing in for the attachment
/// preparation (`PromptSubmissionMapper.map`) that runs between the composer's clear and the thread's send.
@MainActor
final class GatedThreadSource: ComposerThreadSource, Observable {
    let model: ThreadModel
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var held = false

    init(_ model: ThreadModel) { self.model = model }

    var sessionID: SessionID { model.sessionID }
    var draft: String {
        get { model.draft }
        set { model.draft = newValue }
    }
    var isDraftLoaded: Bool { model.isDraftLoaded }
    var isRunning: Bool { model.isRunning }
    var isStopping: Bool { model.isStopping }
    var composerErrorMessage: String? { model.composerErrorMessage }
    var composerDeliveryUnknown: Bool { model.composerDeliveryUnknown }
    var composerPromptHistory: [String] { model.composerPromptHistory }

    func send(_ text: String?, attachments: PromptAttachments, delivery: PromptDelivery?) async -> MessageID? {
        held = true
        await withCheckedContinuation { waiting = $0 }
        return await model.send(text, attachments: attachments, delivery: delivery)
    }

    func open() {
        waiting?.resume()
        waiting = nil
    }

    func runCommand(_ name: String, arguments: String, attachments: PromptAttachments, delivery: PromptDelivery?) async -> Bool {
        await model.runCommand(name, arguments: arguments, attachments: attachments, delivery: delivery)
    }

    func stop() async { await model.stop() }
    func clearError() { model.clearError() }
}

/// Stands in for a composer view: holds the draft value.
@MainActor
final class DraftView {
    var draft = ComposerDraft.empty

    func bind(_ controller: ComposerController) {
        controller.currentDraft = { [unowned self] in draft }
        controller.applyDraft = { [unowned self] in draft = $0 }
        controller.replaceTextUndoably = { [unowned self] in draft = $0 }
    }
}

/// v1.0.2 R4-01: a send in flight never erases another window's newer draft.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct SendDraftRaceTests {
    /// Two windows show one thread. The first sends a prompt with a mention; while its attachments are prepared, the
    /// second window saves a new draft with the same text and a different mention. Dispatch must not clear it: only
    /// the submitted revision's clear belongs to the send, never a draft that merely has the same words.
    @Test func aSendInFlightNeverClearsANewerDraftWithTheSameText() async throws {
        let shell = try await IntegratedShellTests.Shell.start()
        defer { Task { await shell.stop() } }
        let threads = shell.threads
        try #require(!threads.isEmpty)
        let model = shell.engine.openThread(threads[0])
        defer { model.close() }
        #expect(await waitUntil(timeout: .seconds(5)) { model.isDraftLoaded })
        let source = GatedThreadSource(model)
        let registry = ComposerController.Registry()
        let cache = ComposerDraftCache()
        var hosts: [ThreadModelComposerHost] = []
        var views: [DraftView] = []
        var controllers: [ComposerController] = []
        for _ in 0..<2 {
            let host = ThreadModelComposerHost(source, cache: cache)
            let controller = ComposerController(registry: registry)
            let view = DraftView()
            view.bind(controller)
            controller.attach(host)
            hosts.append(host)
            views.append(view)
            controllers.append(controller)
        }
        let text = "review @a.swift"
        let sent = ComposerToken(kind: .file, text: "@a.swift", value: "Sources/a.swift")
        let newer = ComposerToken(kind: .file, text: "@a.swift", value: "Tests/a.swift")
        let range = NSRange(location: 7, length: 8)

        // The first window sends its prompt; the send waits while its attachments are prepared.
        views[0].draft = ComposerDraft(text: text, tokens: [PlacedToken(token: sent, range: range)])
        controllers[0].draftDidChange()
        controllers[0].flushDraft()
        #expect(controllers[0].submit())
        #expect(model.draft == "", "the submitted revision is cleared at once")
        #expect(await waitUntil(timeout: .seconds(5)) { source.held })

        // Meanwhile the second window saves a new draft: the same words, another file's mention.
        controllers[1].followStoredDraft()
        views[1].draft = ComposerDraft(text: text, tokens: [PlacedToken(token: newer, range: range)])
        controllers[1].draftDidChange()
        controllers[1].flushDraft()
        #expect(model.draft == text)

        source.open()
        #expect(await waitUntil(timeout: .seconds(10)) { controllers[0].pendingSends == 0 })
        #expect(controllers[0].errorMessage == nil, "\(controllers[0].errorMessage ?? "")")
        #expect(model.draft == text, "the newer draft is not cleared by the send")
        #expect(hosts[1].loadDraft().tokens == [PlacedToken(token: newer, range: range)], "with its own mention")
        // Both windows show the newer draft (not cleared under the second window's editor).
        for controller in controllers { controller.followStoredDraft() }
        #expect(views[1].draft.text == text)
        #expect(views[1].draft.tokens == [PlacedToken(token: newer, range: range)])
        #expect(views[0].draft.text == text)
    }
}
