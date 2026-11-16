import Foundation

/// What a prompt carries besides its text: files (by URI), agent mentions and skill mentions.
///
/// Maps onto opencode 2.3.0's `PromptInput` (`files: [PromptInput.FileAttachment]`, `agents: [Prompt.AgentAttachment]`,
/// `skills: [PromptInput.SkillAttachment]`). There is no byte field on input: every file is a URI the server reads
/// (pasted images and large pastes are written to app-owned files first).
public struct PromptAttachments: Hashable, Sendable, Codable {
    /// Where a mention sits in the prompt text: UTF-16 offsets (as JavaScript counts), end exclusive.
    public struct Mention: Hashable, Sendable, Codable {
        public var start: Int
        public var end: Int
        public var text: String

        public init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct File: Hashable, Sendable, Codable {
        /// A `file://` URL (or any URI the server understands).
        public var uri: String
        public var name: String?
        /// Shown in the optimistic message until the server's copy arrives; not sent.
        public var mime: String
        /// Set for `@` mentions in the text; nil for attachments.
        public var mention: Mention?

        public init(uri: String, name: String? = nil, mime: String = "application/octet-stream", mention: Mention? = nil) {
            self.uri = uri
            self.name = name
            self.mime = mime
            self.mention = mention
        }
    }

    public struct Agent: Hashable, Sendable, Codable {
        public var name: String
        public var mention: Mention?

        public init(name: String, mention: Mention? = nil) {
            self.name = name
            self.mention = mention
        }
    }

    public struct Skill: Hashable, Sendable, Codable {
        public var id: String
        public var mention: Mention?

        public init(id: String, mention: Mention? = nil) {
            self.id = id
            self.mention = mention
        }
    }

    public var files: [File]
    public var agents: [Agent]
    public var skills: [Skill]

    public init(files: [File] = [], agents: [Agent] = [], skills: [Skill] = []) {
        self.files = files
        self.agents = agents
        self.skills = skills
    }

    public static let none = PromptAttachments()

    public var isEmpty: Bool { files.isEmpty && agents.isEmpty && skills.isEmpty }
}
