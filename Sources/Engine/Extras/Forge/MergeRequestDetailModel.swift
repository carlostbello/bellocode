import Foundation

// Values behind the merge-request panel, triage, babysit and the agent tools (docs/features/gitlab.md). All Sendable,
// built off the main actor by `GitLabProvider`. Text that came from GitLab (titles aside) is external and untrusted:
// it is shown as data and handed to models only through `UntrustedText`.

public struct PipelineStage: Hashable, Sendable, Identifiable {
    public var name: String
    public var jobs: [PipelineJob]
    public var id: String { name }

    public init(name: String, jobs: [PipelineJob]) {
        self.name = name
        self.jobs = jobs
    }

    /// The stage's worst state, for its header.
    public var status: String {
        if jobs.contains(where: { $0.isFailure && $0.allowFailure != true }) { return "failed" }
        if jobs.contains(where: { $0.status == "running" }) { return "running" }
        if jobs.contains(where: { ["pending", "created", "preparing", "waiting_for_resource", "scheduled"].contains($0.status) }) { return "pending" }
        if jobs.contains(where: { $0.isManual }) { return "manual" }
        if jobs.allSatisfy({ ["success", "skipped"].contains($0.status) || ($0.isFailure && $0.allowFailure == true) }) { return "success" }
        return jobs.first?.status ?? "unknown"
    }
}

/// One note of a discussion (bounded body).
public struct NoteDigest: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var author: String
    /// Cut at `NoteDigest.bodyLimit` characters (`bodyTruncated`).
    public var body: String
    public var bodyTruncated: Bool
    public var system: Bool
    public var created: Date?
    public var resolvable: Bool
    public var resolved: Bool

    public static let bodyLimit = 4_000

    public init(id: Int, author: String, body: String, system: Bool = false, created: Date? = nil, resolvable: Bool = false, resolved: Bool = false) {
        self.id = id
        self.author = author
        self.bodyTruncated = body.count > Self.bodyLimit
        self.body = String(body.prefix(Self.bodyLimit))
        self.system = system
        self.created = created
        self.resolvable = resolvable
        self.resolved = resolved
    }
}

/// A discussion thread on the MR: general or on a diff line.
public struct DiscussionDigest: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var notes: [NoteDigest]
    /// "src/parser.swift:42" for a diff note.
    public var position: String?
    public var individual: Bool

    public init(id: String, notes: [NoteDigest], position: String? = nil, individual: Bool = false) {
        self.id = id
        self.notes = notes
        self.position = position
        self.individual = individual
    }

    public var isResolvable: Bool { notes.contains { $0.resolvable } }
    public var isUnresolved: Bool { notes.contains { $0.resolvable && !$0.resolved } }
    /// Only system notes ("added 1 commit"): hidden from the review list.
    public var isSystem: Bool { notes.allSatisfy(\.system) }
    public var lastActivity: Date? { notes.compactMap(\.created).max() }
}

/// A required approval rule (Premium/Ultimate; `approval_state`).
public struct ApprovalRuleDigest: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    /// "regular", "code_owner", "any_approver", "report_approver".
    public var type: String
    public var required: Int
    public var approvedBy: [String]
    public var approved: Bool
    /// Code Owners section or path, when GitLab names it.
    public var section: String?
    public var id: String { type + ":" + name }

    public init(name: String, type: String, required: Int, approvedBy: [String], approved: Bool, section: String? = nil) {
        self.name = name
        self.type = type
        self.required = required
        self.approvedBy = approvedBy
        self.approved = approved
        self.section = section
    }

    public var isCodeOwner: Bool { type == "code_owner" }
}

/// `GET /projects/:id`.
public struct GitLabProjectInfo: Hashable, Sendable, Codable {
    public var id: Int
    public var path: String
    public var defaultBranch: String?
    public var webURL: String?

    public init(id: Int, path: String, defaultBranch: String? = nil, webURL: String? = nil) {
        self.id = id
        self.path = path
        self.defaultBranch = defaultBranch
        self.webURL = webURL
    }
}

public struct GitLabUserRef: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var username: String
    public var name: String

    public init(id: Int, username: String, name: String = "") {
        self.id = id
        self.username = username
        self.name = name
    }
}

/// A bounded read of a job's log. `text` is raw (ANSI and GitLab section markers included) and possibly the tail only.
public struct JobLogChunk: Hashable, Sendable {
    public var jobID: Int
    public var text: String
    /// The log's full size when known (from `Content-Range`, or the bytes read).
    public var totalBytes: Int?
    /// Only the end of the log is here (the head was skipped or dropped at the bound).
    public var headOmitted: Bool
    /// Whether the server honoured a byte range (nil: not tried).
    public var rangeHonoured: Bool?

    public init(jobID: Int, text: String, totalBytes: Int? = nil, headOmitted: Bool = false, rangeHonoured: Bool? = nil) {
        self.jobID = jobID
        self.text = text
        self.totalBytes = totalBytes
        self.headOmitted = headOmitted
        self.rangeHonoured = rangeHonoured
    }
}

/// One file of a merge request's changes (bounded).
public struct MergeRequestFileChange: Hashable, Sendable {
    public var oldPath: String
    public var newPath: String
    public var newFile: Bool
    public var deletedFile: Bool
    public var renamedFile: Bool
    /// Unified diff, cut at the per-file bound (`truncated`), empty for binary or collapsed files.
    public var diff: String
    public var truncated: Bool
    /// GitLab collapsed it or found it too large: the content is missing, not empty.
    public var tooLarge: Bool
}

public struct MergeRequestChanges: Hashable, Sendable {
    public var files: [MergeRequestFileChange]
    /// More files than were read, or bytes dropped at the total bound.
    public var incomplete: Bool
}

/// A merge request the person is about to create (the inline form) or an agent asked to create. `payload` is exactly
/// what is POSTed; the form's preview shows it.
public struct MergeRequestDraft: Hashable, Sendable, Codable {
    public var sourceBranch: String
    public var targetBranch: String
    public var title: String
    public var description: String
    public var draft: Bool
    public var assigneeIDs: [Int]
    public var reviewerIDs: [Int]
    public var removeSourceBranch: Bool

    public init(
        sourceBranch: String, targetBranch: String, title: String, description: String = "", draft: Bool = false, assigneeIDs: [Int] = [],
        reviewerIDs: [Int] = [], removeSourceBranch: Bool = false
    ) {
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.title = title
        self.description = description
        self.draft = draft
        self.assigneeIDs = assigneeIDs
        self.reviewerIDs = reviewerIDs
        self.removeSourceBranch = removeSourceBranch
    }

    /// The title GitLab receives: drafts use the `Draft:` prefix (works on every version; no `draft` field assumed).
    public var effectiveTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = Self.stripDraftPrefix(trimmed)
        return draft ? "Draft: " + bare : bare
    }

    public static func stripDraftPrefix(_ title: String) -> String {
        for prefix in ["Draft:", "[Draft]", "(Draft)", "WIP:", "[WIP]"] where title.lowercased().hasPrefix(prefix.lowercased()) {
            return String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    /// Problems that block creation (empty when it can be sent).
    public var problems: [String] {
        var list: [String] = []
        if Self.stripDraftPrefix(title.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty { list.append("Give a title.") }
        if sourceBranch.isEmpty { list.append("This thread's checkout has no branch.") }
        if targetBranch.isEmpty { list.append("Choose a target branch.") }
        if !sourceBranch.isEmpty, sourceBranch == targetBranch { list.append("The source and target branch are the same.") }
        if description.utf8.count > 1_000_000 { list.append("The description is too long.") }
        return list
    }

    /// The JSON object POSTed to `/projects/:id/merge_requests` (keys sorted in the preview).
    public var payload: [String: JSONLike] {
        var object: [String: JSONLike] = [
            "source_branch": .string(sourceBranch), "target_branch": .string(targetBranch), "title": .string(effectiveTitle),
            "description": .string(description), "remove_source_branch": .bool(removeSourceBranch),
        ]
        if !assigneeIDs.isEmpty { object["assignee_ids"] = .array(assigneeIDs.map { .int($0) }) }
        if !reviewerIDs.isEmpty { object["reviewer_ids"] = .array(reviewerIDs.map { .int($0) }) }
        return object
    }

    /// The payload as pretty, key-sorted JSON (the preview and the approval card show this text).
    public var payloadText: String { JSONLike.object(payload).prettyText }
}

/// A small JSON value for request payloads (sorted, printable, hashable): what a card shows is exactly what is sent.
public indirect enum JSONLike: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONLike])
    case object([String: JSONLike])

    public var foundation: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        case .array(let items): items.map(\.foundation)
        case .object(let entries): entries.mapValues(\.foundation)
        }
    }

    public var data: Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    public var prettyText: String {
        let data = (try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
