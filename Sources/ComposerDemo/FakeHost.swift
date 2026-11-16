import ComposerKit
import Foundation

/// An in-memory thread for the demo: records sends, can fail or delay them, and can pretend the agent runs.
@MainActor
final class FakeHost: ComposerHost {
    let draftKey: String
    var draft: ComposerDraft
    var runState: ComposerRunState = .idle { didSet { notify() } }
    var supportsSteer = true { didSet { notify() } }
    var supportsAttachments = true
    var errorMessage: String? { didSet { notify() } }
    var prompts: [String]
    var submissions: [ComposerSubmission] = []
    var saves = 0
    var stopCalls = 0
    /// Failure messages for the next sends, in order.
    var failures: [String] = []
    var sendDelay: Duration = .milliseconds(20)
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(key: String, draft: ComposerDraft = .empty, prompts: [String] = []) {
        draftKey = key
        self.draft = draft
        self.prompts = prompts
    }

    func loadDraft() -> ComposerDraft { draft }

    func saveDraft(_ draft: ComposerDraft) {
        self.draft = draft
        saves += 1
    }

    func send(_ submission: ComposerSubmission) async -> ComposerSendOutcome {
        try? await Task.sleep(for: sendDelay)
        if !failures.isEmpty { return .failed(failures.removeFirst()) }
        submissions.append(submission)
        prompts.append(submission.text)
        return .accepted
    }

    func stop() async {
        stopCalls += 1
        runState = .stopping
    }

    func clearError() { errorMessage = nil }
    func recentPrompts() -> [String] { prompts }

    func observe(_ onChange: @escaping @MainActor () -> Void) -> ComposerObservation {
        let id = UUID()
        observers[id] = onChange
        return ComposerObservation { [weak self] in
            MainActor.assumeIsolated { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    private func notify() { observers.values.forEach { $0() } }
}
