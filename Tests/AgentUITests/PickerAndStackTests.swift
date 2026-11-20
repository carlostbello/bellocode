import BelloCore
import Engine
import Foundation
import Testing

@testable import AgentUI

@Suite("Fuzzy matching")
struct FuzzyMatcherTests {
    @Test func subsequenceRequired() {
        #expect(FuzzyMatcher.score("snt", "Claude Sonnet") != nil)
        #expect(FuzzyMatcher.score("xyz", "Claude Sonnet") == nil)
        #expect(FuzzyMatcher.score("", "anything") == 0)
        #expect(FuzzyMatcher.score("tennos", "Sonnet") == nil)
    }

    @Test func rankingPrefersPrefixesWordStartsAndRuns() {
        func rank(_ query: String, _ names: [String]) -> [String] {
            names.compactMap { name in FuzzyMatcher.score(query, name).map { (name, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        #expect(rank("gpt", ["Gemini Pro Turbo", "GPT mini", "big-pickle-turbo"]).first == "GPT mini")
        #expect(rank("sonet", ["Claude Sonnet", "Claude Haiku", "Sonar"]).first == "Claude Sonnet")
        #expect(rank("bp", ["Big Pickle", "deepseek-flash-preview"]).first == "Big Pickle")
        #expect(rank("glm", ["GLM-5.3-Flash Free", "Gemma Large Model", "big-pickle"]) .first == "GLM-5.3-Flash Free")
        // Case and diacritics do not matter.
        #expect(FuzzyMatcher.score("CLAUDE", "claude") == FuzzyMatcher.score("claude", "Claude"))
        #expect(FuzzyMatcher.score("ecole", "École") != nil)
    }

    @Test func multipleFieldsTakeTheBest() {
        let byID = FuzzyMatcher.score("cs4", fields: ["Claude Sonnet", "claude-sonnet-4"])
        #expect(byID != nil)
        #expect(FuzzyMatcher.score("zz", fields: ["a", "b"]) == nil)
    }
}

@Suite("Model picker model")
@MainActor
struct ModelPickerModelTests {
    static let catalog = Catalog(
        directory: "/p",
        providers: [
            ProviderEntry(id: "opencode", name: "OpenCode", activation: "enabled", integrationID: "opencode"),
            ProviderEntry(id: "anthropic", name: "Anthropic", activation: "auto", integrationID: "anthropic"),
            ProviderEntry(id: "off", name: "Off", activation: "disabled"),
        ],
        models: [
            ModelEntry(providerID: "opencode", modelID: "big-pickle", name: "Big Pickle", contextLimit: 200_000, isFree: true),
            ModelEntry(providerID: "anthropic", modelID: "sonnet", name: "Claude Sonnet", contextLimit: 1_000_000,
                       variants: ["low", "high"], inputCost: 3, outputCost: 15),
            ModelEntry(providerID: "anthropic", modelID: "haiku", name: "Claude Haiku", inputCost: 1, outputCost: 5),
            ModelEntry(providerID: "off", modelID: "x", name: "Disabled Model"),
        ],
        fetched: Timestamp(milliseconds: 0))

    final class Box {
        var current: ModelSelection? = ModelSelection(providerID: "opencode", modelID: "big-pickle")
        var applied: [ModelSelection] = []
        var failNext = false
        var connects: [String?] = []
    }

    func make(_ box: Box, integrations: [IntegrationItem] = []) -> ModelPickerModel {
        ModelPickerModel(
            catalog: { Self.catalog }, current: { box.current }, preferences: ModelPreferencesModel(store: nil),
            apply: { selection in
                box.applied.append(selection)
                if box.failNext {
                    box.failNext = false
                    return "Server error"
                }
                box.current = selection
                return nil
            },
            integrations: { integrations }, onConnect: { box.connects.append($0) })
    }

    @Test func sectionsFavouritesRecentsAndDisabled() {
        let box = Box()
        let model = make(box)
        model.preferences.update {
            $0.toggleFavourite("anthropic/sonnet")
            $0.recordUse(ModelSelection(providerID: "anthropic", modelID: "haiku"))
        }
        let titles = model.sections.map(\.title)
        #expect(titles.prefix(4) == ["Favourites", "Recent", "OpenCode", "Anthropic"])
        #expect(titles.last == "Not connected")
        let disabled = model.sections.flatMap(\.rows).first { $0.model?.modelID == "x" }
        #expect(disabled?.isEnabled == false)
        #expect(disabled?.disabledReason == "Provider disabled in opencode")
        #expect(!model.selectableRows.contains { $0.model?.modelID == "x" })
        model.preferences.update { $0.setHidden("anthropic/haiku", true) }
        #expect(!model.sections.first { $0.title == "Anthropic" }!.rows.contains { $0.model?.modelID == "haiku" })
        model.showsHidden = true
        #expect(model.sections.first { $0.title == "Anthropic" }!.rows.contains { $0.model?.modelID == "haiku" })
    }

    /// Settings ▸ Models rows: non-model choices first, one of them or a model in effect, both applied through the picker.
    @Test func choicesComeFirstAndApplyLikeModels() async {
        let box = Box()
        let model = make(box)
        var choice: String? = "thread"
        var applied: [String] = []
        model.choices = { [.init(id: "thread", title: "Same as thread", detail: "Anthropic · Claude Sonnet"), .init(id: "server", title: "Server default")] }
        model.currentChoice = { choice }
        model.applyChoice = { item in
            applied.append(item.id)
            choice = item.id
            return nil
        }
        model.shortcutHint = nil
        #expect(model.sections.first?.id == "choices")
        #expect(model.sections.first?.title == "Use")
        model.prepareForOpen()
        #expect(model.highlightedRow?.id == "choice|thread", "the choice in effect is highlighted, not the model")
        // A model replaces the choice (even the model the picker would show as current).
        let pickle = model.selectableRows.first { $0.model?.modelID == "sonnet" }!
        #expect(model.choose(pickle))
        await model.settle()
        #expect(box.applied.last?.modelID == "sonnet")
        choice = nil
        // A choice replaces the model.
        let server = model.selectableRows.first { $0.id == "choice|server" }!
        #expect(model.choose(server))
        await model.settle()
        #expect(applied == ["server"])
        #expect(model.isChosen(.init(id: "server", title: "Server default")))
        // Search filters the choices too.
        model.query = "same"
        #expect(model.sections.first?.rows.map(\.id) == ["choice|thread"])
        model.query = "sonnet"
        #expect(model.sections.first?.id != "choices")
    }

    @Test func keyboardSelectionVariantAndApply() async {
        let box = Box()
        let model = make(box)
        model.prepareForOpen()
        #expect(model.highlightedRow?.model?.modelID == "big-pickle")
        model.query = "sonnet"
        #expect(model.highlightedRow?.model?.modelID == "sonnet")
        model.cycleVariant(1)
        #expect(model.variant(for: model.highlightedRow!.model!) == "low")
        model.cycleVariant(-1)
        model.cycleVariant(-1)
        #expect(model.variant(for: model.highlightedRow!.model!) == "high")
        #expect(model.chooseHighlighted())
        #expect(model.pending == ModelSelection(providerID: "anthropic", modelID: "sonnet", variant: "high"))
        await model.settle()
        #expect(model.pending == nil)
        #expect(box.current?.variant == "high")
        #expect(model.preferences.value.recents.first == "anthropic/sonnet")
        #expect(model.preferences.value.variants["anthropic/sonnet"] == "high")
    }

    @Test func failedApplyRollsBackWithAnError() async {
        let box = Box()
        let model = make(box)
        box.failNext = true
        model.select(ModelSelection(providerID: "anthropic", modelID: "haiku"))
        #expect(model.selection?.modelID == "haiku")
        await model.settle()
        #expect(model.selection?.modelID == "big-pickle")
        #expect(model.error == "Server error")
        #expect(model.preferences.value.recents.isEmpty)
    }

    @Test func notConnectedProvidersOfferConnect() {
        let box = Box()
        let openai = IntegrationItem(
            id: "openai", name: "OpenAI",
            methods: [AuthMethod(kind: .key, methodID: nil, label: "API key", fields: [], command: [], environmentNames: [])],
            connections: [])
        let model = make(box, integrations: [openai])
        let connect = model.sections.last!.rows
        #expect(connect.map(\.id) == ["connect|openai", "connect|*"])
        model.query = "openai"
        let row = model.highlightedRow!
        #expect(row.id == "connect|openai")
        #expect(model.choose(row))
        #expect(box.connects == ["openai"])
    }

    @Test func formatting() {
        #expect(ModelPickerModel.contextLabel(200_000) == "200K")
        #expect(ModelPickerModel.contextLabel(1_000_000) == "1M")
        #expect(ModelPickerModel.contextLabel(1_500_000) == "1.5M")
        #expect(ModelPickerModel.contextLabel(0) == nil)
        #expect(ModelPickerModel.costLabel(Self.catalog.models[0]) == "Free")
        #expect(ModelPickerModel.costLabel(Self.catalog.models[1]) == "$3 / $15")
        #expect(ModelPickerModel.costLabel(ModelEntry(providerID: "p", modelID: "m", name: "M", inputCost: 0.25, outputCost: 2)) == "$0.25 / $2")
    }
}

@Suite("Request stack model")
@MainActor
struct PendingRequestStackModelTests {
    final class FakeSource: PendingRequestSource {
        let sessionID = SessionID("ses_parent")
        var session: Session? = Session(
            id: SessionID("ses_parent"), projectID: ProjectID("p"), title: "Parent", directory: "/p", agent: "build",
            created: Timestamp(milliseconds: 0), updated: Timestamp(milliseconds: 0))
        var pendingRequests: [PendingRequest] = []
        var submittingRequestIDs: Set<String> = []
        var lastError: EngineError?
        var replies: [(String, PermissionReply, String?)] = []
        var answers: [(String, [String: QuestionAnswer])] = []
        var dismissed: [String] = []

        func reply(to id: PermissionRequestID, _ reply: PermissionReply, message: String?) async {
            replies.append((id.rawValue, reply, message))
            pendingRequests.removeAll { $0.id == id.rawValue }
        }

        func answer(_ id: QuestionID, _ answers: [String: QuestionAnswer]) async {
            self.answers.append((id.rawValue, answers))
            pendingRequests.removeAll { $0.id == id.rawValue }
        }

        func dismiss(_ id: QuestionID) async {
            dismissed.append(id.rawValue)
            pendingRequests.removeAll { $0.id == id.rawValue }
        }

        /// App requests: resolved unless `failAppResponses` (the engine threw; the card stays).
        var failAppResponses = false
        var appResponses: [AppRequestResponse] = []
        func respond(to request: AppRequest, _ response: AppRequestResponse) async {
            appResponses.append(response)
            if failAppResponses { lastError = .failed("save failed"); return }
            pendingRequests.removeAll { $0.id == request.id }
        }
    }

    /// R25: the secret card keeps the typed value until the save succeeds.
    @Test func secretValueIsClearedOnlyAfterASuccessfulSave() async {
        let source = FakeSource()
        let request = AppRequest(id: "app_sec_1", sessionID: SessionID("ses_parent"),
                                 kind: .secret(SecretPrompt(label: "Publish token", reason: "To publish.")), received: Timestamp(milliseconds: 1))
        source.pendingRequests = [.app(request)]
        let model = PendingRequestStackModel(source: source, announce: { _ in })
        let draft = model.secretDraft(for: request)
        draft.text = "typed-value-123"
        draft.choice = SecretChoice(mode: .command)
        source.failAppResponses = true
        await model.saveSecret(request, draft: draft)
        #expect(draft.text == "typed-value-123", "a failed save keeps what the person typed")
        source.failAppResponses = false
        await model.saveSecret(request, draft: draft)
        #expect(draft.text.isEmpty, "cleared once saved")
        #expect(source.appResponses.count == 2)
    }

    func permission(_ id: String, session: String = "ses_parent", action: String = "shell") -> PendingRequest {
        .permission(PermissionRequest(
            id: PermissionRequestID(id), sessionID: SessionID(session), action: action, resources: ["ls"],
            alwaysScopes: ["ls *"], received: Timestamp(milliseconds: 1)))
    }

    @Test func navigationAnnouncementsAndReplies() async {
        let source = FakeSource()
        var announced: [String] = []
        let child = Session(
            id: SessionID("ses_child"), projectID: ProjectID("p"), parentID: SessionID("ses_parent"), title: "Child task",
            directory: "/p/sub", agent: "general", created: Timestamp(milliseconds: 0), updated: Timestamp(milliseconds: 0))
        let model = PendingRequestStackModel(
            source: source, context: PendingRequestContext(projectName: "App") { $0 == child.id ? child : nil },
            announce: { announced.append($0) })
        source.pendingRequests = [permission("per_1"), permission("per_2", session: "ses_child")]
        model.requestsChanged()
        model.requestsChanged()
        #expect(announced.count == 1)
        #expect(announced[0].contains("2 new requests"))
        #expect(model.current?.id == "per_1")
        model.showNext()
        #expect(model.current?.id == "per_2")
        #expect(model.origin(of: model.current!) == "Child task")
        #expect(model.session(of: model.current!)?.agent == "general")
        model.showNext()
        #expect(model.current?.id == "per_1")
        model.showPrevious()
        #expect(model.current?.id == "per_2")

        guard case .permission(let childRequest) = model.current! else { return }
        model.notes["per_2"] = "  not now  "
        await model.reply(.reject, to: childRequest)
        #expect(source.replies.last?.1 == .reject)
        #expect(source.replies.last?.2 == "not now")
        #expect(model.current?.id == "per_1")

        // A request already being submitted is not sent twice.
        source.submittingRequestIDs = ["per_1"]
        guard case .permission(let first) = model.current! else { return }
        await model.reply(.once, to: first)
        #expect(source.replies.count == 1)
        source.submittingRequestIDs = []
        await model.reply(.always, to: first)
        #expect(source.replies.last?.1 == .always)
        #expect(model.current == nil)

        source.pendingRequests = [permission("per_3")]
        model.requestsChanged()
        #expect(announced.count == 2)
    }

    @Test func questionsValidateBeforeSubmitting() async {
        let source = FakeSource()
        let question = QuestionRequest(
            id: QuestionID("frm_1"), sessionID: SessionID("ses_parent"), title: "Pick",
            fields: [QuestionField(key: "a", kind: .text, required: true)], received: Timestamp(milliseconds: 1))
        source.pendingRequests = [.question(question)]
        let model = PendingRequestStackModel(source: source, announce: { _ in })
        #expect(await model.submit(question) == false)
        #expect(source.answers.isEmpty)
        model.form(for: question).text["a"] = "yes"
        #expect(await model.submit(question))
        #expect(source.answers.first?.1 == ["a": .text("yes")])
        source.pendingRequests = [.question(question)]
        await model.dismiss(question)
        #expect(source.dismissed == ["frm_1"])
    }
}

@Suite("Permission mode options")
struct PermissionModeOptionTests {
    @Test func everyModeIsDescribedAndMapsToRules() {
        #expect(PermissionModeOption.all.map(\.mode) == PermissionMode.allCases)
        for option in PermissionModeOption.all {
            #expect(!option.title.isEmpty && !option.allows.isEmpty && !option.asks.isEmpty)
            #expect(PermissionModeRules.mode(from: PermissionModeRules.rules(for: option.mode)) == option.mode)
        }
        // The descriptions match the verified mapping.
        #expect(PermissionModeOption.option(.ask).asks.contains("every edit"))
        #expect(PermissionModeOption.option(.autoEdit).allows.contains("edits"))
        #expect(PermissionModeOption.option(.fullAccess).asks.contains("plan agent still cannot edit"))
    }
}
