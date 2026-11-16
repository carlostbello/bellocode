import Foundation

extension MockIntegration {
    /// A representative subset of the 2.3.0 integration list (332 entries on the real server), covering every method
    /// shape seen there: key only, key with a required form field, OAuth `auto` and `code`, OAuth with a conditional
    /// (`when`) and a hidden field, `external` with a form, plus one `command` method (none exist on 2.3.0; the contract
    /// allows it). Anthropic, OpenAI and Fictional Labs unlock fictional models when connected.
    public static let standard: [MockIntegration] = [
        MockIntegration(
            id: "opencode", name: "OpenCode Console",
            methods: json(#"""
                [{"type":"key","label":"API key (service account)"},{"type":"env","names":["OPENCODE_API_KEY"]},
                 {"id":"device","type":"oauth","label":"OpenCode Console account",
                  "form":[{"key":"server","hidden":true,"type":"string","format":"uri","default":"https://opencode.ai/console"}]}]
                """#)),
        MockIntegration(
            id: "anthropic", name: "Anthropic",
            methods: json(#"[{"type":"key"},{"type":"env","names":["ANTHROPIC_API_KEY"]}]"#),
            providers: [provider("anthropic", "Anthropic")],
            models: [
                model("anthropic", "claude-sonnet-mock", "Claude Sonnet (mock)", family: "claude-sonnet", input: 3, output: 15,
                      variants: ["low", "medium", "high"], context: 1_000_000, image: true),
                model("anthropic", "claude-haiku-mock", "Claude Haiku (mock)", family: "claude-haiku", input: 1, output: 5,
                      variants: [], context: 200_000, image: true),
            ]),
        MockIntegration(
            id: "openai", name: "OpenAI",
            methods: json(#"""
                [{"type":"key"},{"type":"env","names":["OPENAI_API_KEY"]},
                 {"id":"chatgpt-browser","type":"oauth","label":"Sign in with ChatGPT"}]
                """#),
            providers: [provider("openai", "OpenAI")],
            models: [
                model("openai", "gpt-mock", "GPT (mock)", family: "gpt", input: 1.25, output: 10,
                      variants: ["minimal", "low", "medium", "high"], context: 400_000, image: true),
                model("openai", "gpt-mock-mini", "GPT mini (mock)", family: "gpt-mini", input: 0.25, output: 2,
                      variants: ["low", "medium", "high"], context: 400_000, image: false),
            ]),
        MockIntegration(
            id: "github-copilot", name: "GitHub Copilot",
            methods: json(#"""
                [{"type":"env","names":["GITHUB_TOKEN"]},
                 {"id":"device","type":"oauth","label":"Login with GitHub Copilot","form":[
                  {"key":"deploymentType","title":"Select GitHub deployment type","required":true,"type":"string",
                   "options":[{"value":"github.com","label":"GitHub.com","description":"Public"},
                    {"value":"enterprise","label":"GitHub Enterprise","description":"Data residency or self-hosted"}]},
                  {"key":"enterpriseUrl","title":"Enter your GitHub Enterprise URL or domain","required":true,
                   "when":[{"key":"deploymentType","op":"eq","value":"enterprise"}],"type":"string",
                   "placeholder":"company.ghe.com or https://company.ghe.com"}]}]
                """#)),
        MockIntegration(
            id: "gitlab", name: "GitLab Duo",
            methods: json(#"""
                [{"type":"key"},{"type":"env","names":["GITLAB_TOKEN"]},
                 {"id":"pkce","type":"oauth","label":"Login with GitLab (OAuth)","form":[
                  {"key":"instanceUrl","title":"GitLab instance URL",
                   "description":"Leave the default to use gitlab.com, or enter your self-managed GitLab URL.",
                   "type":"string","pattern":"^https?://\\S+$","placeholder":"https://gitlab.com","default":"https://gitlab.com"}]}]
                """#)),
        MockIntegration(
            id: "azure", name: "Azure",
            methods: json(#"""
                [{"type":"key","label":"API key","form":[{"key":"resourceName","title":"Enter Azure Resource Name",
                  "required":true,"type":"string","placeholder":"e.g. my-models"}]},
                 {"type":"env","names":["AZURE_API_KEY","AZURE_COGNITIVE_SERVICES_API_KEY"]}]
                """#)),
        MockIntegration(
            id: "amazon-bedrock", name: "Amazon Bedrock",
            methods: json(#"""
                [{"type":"key","label":"Bedrock API key"},{"type":"env","names":["AWS_BEARER_TOKEN_BEDROCK"]},
                 {"id":"aws-profile","type":"external","label":"AWS profile (SSO or named profile)","form":[
                  {"key":"profile","title":"AWS profile","required":true,"type":"string","minLength":1,"pattern":"\\S",
                   "placeholder":"Profile name","options":[],"custom":true}]}]
                """#)),
        MockIntegration(
            id: "openrouter", name: "OpenRouter",
            methods: json(#"[{"type":"key"},{"type":"env","names":["OPENROUTER_API_KEY"]}]"#)),
        MockIntegration(
            id: "fictional-labs", name: "Fictional Labs",
            methods: json(#"""
                [{"type":"key"},{"id":"cli","type":"command","label":"Log in with the Fictional CLI","command":["fictional","login"]}]
                """#),
            providers: [provider("fictional-labs", "Fictional Labs")],
            models: [model("fictional-labs", "fable-mock", "Fable (mock)", family: "fable", input: 0.5, output: 1.5,
                           variants: [], context: 128_000, image: false)]),
    ]

    private static func json(_ text: String) -> [JSONValue] { (try? JSONValue.parse(text))?.arrayValue ?? [] }

    static func provider(_ id: String, _ name: String) -> JSONValue {
        ["id": .string(id), "integrationID": .string(id), "name": .string(name), "activation": "auto",
         "package": "@opencode/ai/providers/openai-compatible"]
    }

    static func model(
        _ provider: String, _ id: String, _ name: String, family: String, input: Double, output: Double, variants: [String],
        context: Int, image: Bool
    ) -> JSONValue {
        [
            "id": .string(id), "modelID": .string(id), "providerID": .string(provider), "type": "chat",
            "family": .string(family), "name": .string(name),
            "capabilities": ["tools": true, "input": .array(image ? ["text", "image"] : ["text"]), "output": ["text"],
                             "temperature": true],
            "variants": .array(variants.map { ["id": .string($0)] }), "time": ["released": .int(1_790_000_000_000)],
            "cost": [["input": .double(input), "output": .double(output), "cache": ["read": .double(input / 10), "write": .double(input * 1.25)]]],
            "status": "active", "enabled": true, "limit": ["context": .int(context), "output": .int(64_000)],
        ]
    }
}
