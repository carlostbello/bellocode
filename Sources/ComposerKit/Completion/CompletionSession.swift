import Foundation
import os

/// Runs completion queries for the composer: debounced, cancellable, one in flight, results applied only for the
/// query that asked for them. Keeps the previous rows while a refinement loads, and keeps the selected row by
/// identity, so the list does not flicker or jump.
///
/// Threading: `@MainActor`; provider work runs on the provider's own executor.
@MainActor
public final class CompletionSession {
    public enum State: Equatable {
        case closed
        /// First query for this trigger; nothing to show yet.
        case loading(CompletionQuery)
        case showing(CompletionQuery, isRefreshing: Bool)
        case failed(CompletionQuery, String)
    }

    public private(set) var state: State = .closed
    public private(set) var items: [CompletionItem] = []
    public private(set) var selectedIndex = 0
    public var providers: [any CompletionProvider]
    public var debounce: Duration
    /// Called after every visible change.
    public var onChange: (() -> Void)?

    private static let signposter = OSSignposter(subsystem: "app.bellocode", category: "ComposerCompletion")
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(providers: [any CompletionProvider], debounce: Duration = .milliseconds(40)) {
        self.providers = providers
        self.debounce = debounce
    }

    isolated deinit { task?.cancel() }

    public var isOpen: Bool { state != .closed }
    public var query: CompletionQuery? {
        switch state {
        case .closed: nil
        case .loading(let query), .showing(let query, _), .failed(let query, _): query
        }
    }

    public var selectedItem: CompletionItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    /// Trigger characters and whether each needs the prompt start, for `CompletionTriggerDetector`.
    public var triggers: [Character: Bool] {
        Dictionary(providers.map { ($0.trigger, $0.requiresPromptStart) }, uniquingKeysWith: { $0 || $1 })
    }

    public func provider(for trigger: Character) -> (any CompletionProvider)? {
        providers.first { $0.trigger == trigger }
    }

    /// The query at the caret changed (or disappeared).
    public func update(_ newQuery: CompletionQuery?) {
        guard let newQuery, let provider = provider(for: newQuery.trigger) else {
            close()
            return
        }
        if newQuery == query { return }
        let sameTrigger = query?.trigger == newQuery.trigger && query?.range.location == newQuery.range.location
        if sameTrigger, !items.isEmpty {
            state = .showing(newQuery, isRefreshing: true)
        } else {
            items = []
            selectedIndex = 0
            state = .loading(newQuery)
        }
        onChange?()
        generation += 1
        let expected = generation
        let delay = sameTrigger ? debounce : .zero
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let result: Result<[CompletionItem], any Error>
            let signpost = Self.signposter.beginInterval("query")
            do {
                result = .success(try await provider.completions(for: newQuery.text))
            } catch {
                result = .failure(error)
            }
            Self.signposter.endInterval("query", signpost)
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.apply(result, for: newQuery)
        }
    }

    /// Waits for the query in flight (tests and scripted scenarios).
    public func settle() async {
        await task?.value
    }

    private func apply(_ result: Result<[CompletionItem], any Error>, for query: CompletionQuery) {
        switch result {
        case .success(let newItems):
            let selectedID = selectedItem?.id
            items = newItems
            selectedIndex = selectedID.flatMap { id in newItems.firstIndex { $0.id == id } } ?? 0
            state = .showing(query, isRefreshing: false)
        case .failure(let error):
            if error is CancellationError { return }
            items = []
            state = .failed(query, "Suggestions are unavailable.")
        }
        onChange?()
    }

    public func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
        onChange?()
    }

    public func select(index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    public func close() {
        task?.cancel()
        task = nil
        generation += 1
        guard state != .closed else { return }
        state = .closed
        items = []
        selectedIndex = 0
        onChange?()
    }
}
