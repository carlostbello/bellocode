import BelloCore
import Foundation
import Testing

@testable import AgentUI

@Suite("Permission presentation")
struct PermissionPresentationTests {
    func request(_ action: String, _ resources: [String], always: [String] = [], message: String? = nil) -> PermissionRequest {
        PermissionRequest(
            id: PermissionRequestID("per_1"), sessionID: SessionID("ses_1"), action: action, resources: resources,
            alwaysScopes: always, message: message, received: Timestamp(milliseconds: 0))
    }

    /// Every built-in action opencode 2.3.0 asks about gets its own wording; anything else falls back safely.
    @Test(arguments: [
        ("shell", PermissionPresentation.Kind.command), ("bash", .command), ("edit", .edit), ("write", .edit),
        ("patch", .edit), ("multiedit", .edit), ("read", .read), ("list", .read), ("glob", .search), ("grep", .search),
        ("codesearch", .search), ("external_directory", .outsideProject), ("webfetch", .web), ("websearch", .web),
        ("subagent", .subagent), ("task", .subagent), ("skill", .skill), ("browser", .browser), ("question", .question),
        ("doom_loop", .repetition), ("mcp__github__create_issue", .other), ("", .other), ("🙂 weird action", .other),
    ])
    func everyActionHasAReadableDescription(action: String, kind: PermissionPresentation.Kind) {
        let presentation = PermissionPresentation(request(action, ["/p/a.swift"]), directory: "/p", projectName: "App")
        #expect(presentation.kind == kind)
        #expect(!presentation.title.isEmpty)
        #expect(!presentation.symbolName.isEmpty)
        #expect(!presentation.allowOnce.detail.isEmpty)
        #expect(!presentation.deny.detail.isEmpty)
        #expect(presentation.announcement.hasPrefix("Approval needed: "))
        if kind == .other { #expect(presentation.title.hasPrefix("Use “")) }
    }

    @Test func commandShowsTheCommandAndTheProjectScopeOfAlways() {
        let presentation = PermissionPresentation(
            request("shell", ["npm test"], always: ["npm *"]), directory: "/Users/me/app", projectName: "app")
        #expect(presentation.title == "Run a command")
        #expect(presentation.summary == "npm test")
        #expect(presentation.targetsAreCommands)
        #expect(presentation.caution == nil)
        #expect(presentation.alwaysRules == ["shell npm *"])
        #expect(presentation.allowAlways.isAvailable)
        #expect(presentation.allowAlways.detail.contains("“app”"))
        #expect(presentation.allowAlways.detail.contains("every thread of the project"))
        #expect(presentation.allowOnce.detail.contains("asks again"))
    }

    @Test func pathsAreRelativeAndSecretsAreFlagged() {
        let edit = PermissionPresentation(
            request("edit", ["/Users/me/app/Sources/A.swift", "/Users/me/app/B.swift", "/tmp/x"]), directory: "/Users/me/app",
            projectName: nil)
        #expect(edit.targets == ["Sources/A.swift", "B.swift", "/tmp/x"])
        #expect(edit.title == "Edit 3 files")
        #expect(edit.summary == "Sources/A.swift and 2 more")
        // No save patterns: "always" is unavailable and says why.
        #expect(!edit.allowAlways.isAvailable)

        let env = PermissionPresentation(request("read", ["/Users/me/app/.env"]), directory: "/Users/me/app", projectName: nil)
        #expect(env.caution?.contains("secrets") == true)
        let example = PermissionPresentation(request("read", ["/Users/me/app/.env.example"]), directory: "/Users/me/app", projectName: nil)
        #expect(example.caution == nil)
        let local = PermissionPresentation(request("read", ["/a/.env.local"]), directory: "/a", projectName: nil)
        #expect(local.caution != nil)
    }

    @Test func destructiveCommandsAndEmptyResources() {
        #expect(PermissionPresentation(request("shell", ["rm -rf build"]), directory: nil, projectName: nil).caution != nil)
        #expect(PermissionPresentation(request("shell", ["git reset --hard HEAD~1"]), directory: nil, projectName: nil).caution != nil)
        #expect(PermissionPresentation(request("shell", ["ls -la"]), directory: nil, projectName: nil).caution == nil)
        let empty = PermissionPresentation(request("browser", [], message: "Open the docs"), directory: nil, projectName: nil)
        #expect(empty.summary == "Open the docs")
        let star = PermissionPresentation(request("skill", ["*"]), directory: nil, projectName: nil)
        #expect(star.summary == "No details given")
        let outside = PermissionPresentation(request("external_directory", ["/etc/*"]), directory: "/Users/me/app", projectName: nil)
        #expect(outside.caution?.contains("app") == true)
    }
}

@Suite("Question form model")
@MainActor
struct QuestionFormModelTests {
    func field(
        _ key: String, _ kind: QuestionField.Kind, required: Bool = false, options: [String] = [], custom: Bool = false,
        default value: QuestionAnswer? = nil, hidden: Bool = false, when: [QuestionField.Condition] = [],
        validation: QuestionField.Validation = .init(), title: String? = nil
    ) -> QuestionField {
        QuestionField(
            key: key, kind: kind, title: title, required: required,
            options: options.map { QuestionField.Option(value: $0, label: $0.capitalized) }, allowsCustom: custom,
            defaultValue: value, hidden: hidden, conditions: when, validation: validation)
    }

    @Test func singleChoiceWithCustomAnswer() {
        let form = QuestionFormModel(fields: [field("runner", .text, required: true, options: ["swift test", "make"], custom: true)])
        #expect(!form.validateForSubmit())
        #expect(form.visibleError(for: form.fields[0]) == "Choose one.")
        form.choice["runner"] = QuestionFormModel.other
        #expect(form.error(for: form.fields[0]) == "Type your answer.")
        form.text["runner"] = "  just test "
        #expect(form.isValid)
        #expect(form.answers() == ["runner": .text("just test")])
        form.choice["runner"] = "make"
        #expect(form.answers() == ["runner": .text("make")])
    }

    @Test func multiselectBoundsAndCustom() {
        let form = QuestionFormModel(fields: [
            field("targets", .multiselect, required: true, options: ["ios", "mac", "web"], custom: true,
                  validation: .init(minItems: 1, maxItems: 2)),
        ])
        #expect(form.error(for: form.fields[0]) == "Choose at least one.")
        form.selections["targets"] = ["web", "ios", "mac"]
        #expect(form.error(for: form.fields[0]) == "Choose at most 2.")
        form.selections["targets"] = ["web", "ios"]
        #expect(form.answers() == ["targets": .choices(["ios", "web"])])
        form.selections["targets"]?.insert(QuestionFormModel.other)
        #expect(form.error(for: form.fields[0]) == "Type your answer, or clear “Other”.")
    }

    @Test func numbersBooleansAndTextRules() {
        let form = QuestionFormModel(fields: [
            field("count", .integer, required: true, validation: .init(minimum: 1, maximum: 10)),
            field("ratio", .number),
            field("verbose", .boolean, default: .bool(true)),
            field("url", .text, validation: .init(format: "uri")),
            field("name", .text, validation: .init(pattern: "^[a-z]+$", minLength: 2)),
        ])
        form.text["count"] = "3.5"
        #expect(form.error(for: form.fields[0]) == "Enter a whole number.")
        form.text["count"] = "12"
        #expect(form.error(for: form.fields[0]) == "At most 10.")
        form.text["count"] = "4"
        form.text["ratio"] = "abc"
        #expect(form.error(for: form.fields[1]) == "Enter a number.")
        form.text["ratio"] = ""
        form.text["url"] = "example.com"
        #expect(form.error(for: form.fields[3]) == "Enter a full URL, including https://.")
        form.text["url"] = "https://example.com"
        form.text["name"] = "a"
        #expect(form.error(for: form.fields[4]) == "At least 2 characters.")
        form.text["name"] = "Ab"
        #expect(form.error(for: form.fields[4]) == "Doesn’t match the expected format.")
        form.text["name"] = "ab"
        #expect(form.isValid)
        #expect(form.answers() == [
            "count": .number(4), "verbose": .bool(true), "url": .text("https://example.com"), "name": .text("ab"),
        ])
    }

    @Test func conditionsHideFieldsAndHiddenDefaultsAreSubmitted() {
        let form = QuestionFormModel(fields: [
            field("deploymentType", .text, required: true, options: ["github.com", "enterprise"]),
            field("enterpriseUrl", .text, required: true,
                  when: [QuestionField.Condition(key: "deploymentType", equals: true, value: .text("enterprise"))]),
            field("server", .text, default: .text("https://opencode.ai/console"), hidden: true),
        ])
        #expect(form.visibleFields.map(\.key) == ["deploymentType"])
        form.choice["deploymentType"] = "github.com"
        #expect(form.isValid)
        #expect(form.answers() == ["deploymentType": .text("github.com"), "server": .text("https://opencode.ai/console")])
        form.choice["deploymentType"] = "enterprise"
        #expect(form.visibleFields.map(\.key) == ["deploymentType", "enterpriseUrl"])
        #expect(!form.isValid)
        form.text["enterpriseUrl"] = "company.ghe.com"
        #expect(form.answers()["enterpriseUrl"] == .text("company.ghe.com"))
        // Switching back drops the hidden field's answer but keeps the typed text.
        form.choice["deploymentType"] = "github.com"
        #expect(form.answers()["enterpriseUrl"] == nil)
        #expect(form.text["enterpriseUrl"] == "company.ghe.com")
    }

    @Test func secretFieldsAreDetectedAndNeverDescribed() {
        let token = field("apiToken", .text, title: "GitHub token")
        let plain = field("profile", .text, title: "AWS profile")
        #expect(QuestionFormModel.isSecret(token))
        #expect(!QuestionFormModel.isSecret(plain))
        let form = QuestionFormModel(fields: [token])
        form.text["apiToken"] = "ghp_secret"
        #expect(!String(describing: form).contains("ghp_secret"))
    }

    @Test func externalFieldsSubmitNothing() {
        let form = QuestionFormModel(fields: [
            QuestionField(key: "auth", kind: .external, title: "Sign in", url: "https://example.com/auth"),
        ])
        #expect(form.isValid)
        #expect(form.answers().isEmpty)
    }
}
