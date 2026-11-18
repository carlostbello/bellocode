import BelloCore
import Foundation
import OpenCodeKit

/// Agent-facing GitLab tools (client MCP, `bellocode_app_gitlab_*`; docs/features/gitlab.md, "Agent tools"). The app
/// is the broker: the plugin and the model never see the token. Each call is attributed to its session and scoped to
/// the thread's GitLab project (from its `origin` remote) or to MRs linked to the thread. External text comes back
/// labelled and delimited as untrusted. Writes need the instance's write switch and, unless the thread runs with full
/// access in its own project, an approval card showing host, project, MR, SHA and the exact payload. Manual jobs
/// always need a card. There is no tool to approve, merge, close or change protected branches.
public enum GitLabTools {
    public static let readMergeRequest = "gitlab_read_merge_request"
    public static let readChanges = "gitlab_read_changes"
    public static let listDiscussions = "gitlab_list_discussions"
    public static let readPipeline = "gitlab_read_pipeline"
    public static let readJobLog = "gitlab_read_job_log"
    public static let readApprovals = "gitlab_read_approvals"
    public static let createMergeRequest = "gitlab_create_merge_request"
    public static let updateMergeRequest = "gitlab_update_merge_request"
    public static let replyToDiscussion = "gitlab_reply_to_discussion"
    public static let resolveDiscussion = "gitlab_resolve_discussion"
    public static let retryJob = "gitlab_retry_job"
    public static let playJob = "gitlab_play_manual_job"

    public static let reads = [readMergeRequest, readChanges, listDiscussions, readPipeline, readJobLog, readApprovals]
    public static let writes = [createMergeRequest, updateMergeRequest, replyToDiscussion, resolveDiscussion, retryJob, playJob]
    public static let all = reads + writes

    static let refField = ExtrasTools.string("MR URL, or !iid in this thread's GitLab project. Default: the thread's only linked MR.")

    public static let definitions: [ClientMCPTool] = [
        ClientMCPTool(
            name: readMergeRequest,
            description: "Read a GitLab merge request: state, branches, head SHA, pipeline, approvals, unresolved discussions and its description (quoted as untrusted text).",
            inputSchema: ExtrasTools.object(["ref": refField])),
        ClientMCPTool(
            name: readChanges, description: "Read a merge request's changed files and diffs (bounded; says when cut).",
            inputSchema: ExtrasTools.object(["ref": refField, "path": ExtrasTools.string("Only files whose path contains this.")])),
        ClientMCPTool(
            name: listDiscussions, description: "List a merge request's discussions with their IDs, positions and notes (untrusted text).",
            inputSchema: ExtrasTools.object(["ref": refField, "unresolvedOnly": ExtrasTools.boolean("Only unresolved threads (default true).")])),
        ClientMCPTool(
            name: readPipeline, description: "Read the merge request's head pipeline: stages, jobs with IDs, statuses and failure reasons.",
            inputSchema: ExtrasTools.object(["ref": refField])),
        ClientMCPTool(
            name: readJobLog,
            description: "Read a CI job's log: a sanitised excerpt (first error block plus the end), bounded, quoted as untrusted output. Secret-looking values are redacted.",
            inputSchema: ExtrasTools.object(["ref": refField, "jobID": ExtrasTools.number("The job ID (from gitlab_read_pipeline).")], required: ["jobID"])),
        ClientMCPTool(
            name: readApprovals, description: "Read who approved a merge request and, where the instance reports them, the required rules and Code Owners.",
            inputSchema: ExtrasTools.object(["ref": refField])),
        ClientMCPTool(
            name: createMergeRequest,
            description: "Ask to create a merge request from this thread's pushed branch. The user approves the exact request on a card unless policy allows it; you are woken with the result. Push first with git.",
            inputSchema: ExtrasTools.object(
                [
                    "title": ExtrasTools.string("Title (no Draft: prefix; use draft)."), "description": ExtrasTools.string("Markdown description."),
                    "targetBranch": ExtrasTools.string("Default: the project's default branch."), "draft": ExtrasTools.boolean("Create as draft."),
                ], required: ["title"])),
        ClientMCPTool(
            name: updateMergeRequest, description: "Ask to change a merge request's title and/or description (approval card as policy requires).",
            inputSchema: ExtrasTools.object(["ref": refField, "title": ExtrasTools.string("New title."), "description": ExtrasTools.string("New description.")])),
        ClientMCPTool(
            name: replyToDiscussion, description: "Ask to reply in a merge-request discussion (approval card as policy requires).",
            inputSchema: ExtrasTools.object(
                ["ref": refField, "discussionID": ExtrasTools.string("From gitlab_list_discussions."), "body": ExtrasTools.string("Markdown reply.")],
                required: ["discussionID", "body"])),
        ClientMCPTool(
            name: resolveDiscussion, description: "Ask to resolve or unresolve a merge-request discussion (approval card as policy requires).",
            inputSchema: ExtrasTools.object(
                ["ref": refField, "discussionID": ExtrasTools.string("From gitlab_list_discussions."), "resolved": ExtrasTools.boolean("true to resolve (default), false to reopen.")],
                required: ["discussionID"])),
        ClientMCPTool(
            name: retryJob, description: "Ask to retry a finished CI job of the merge request's pipeline (approval card as policy requires).",
            inputSchema: ExtrasTools.object(["ref": refField, "jobID": ExtrasTools.number("The job ID.")], required: ["jobID"])),
        ClientMCPTool(
            name: playJob, description: "Ask to run a manual CI job (it may deploy). Always needs the user's approval on a card.",
            inputSchema: ExtrasTools.object(["ref": refField, "jobID": ExtrasTools.number("The manual job's ID.")], required: ["jobID"])),
    ]
}

/// A GitLab change an agent asked for, waiting on its card (in memory: after a relaunch the card cannot apply).
struct PendingGitLabWrite: Sendable {
    enum Action: Sendable {
        case create(ForgeProject, MergeRequestDraft)
        case update(MergeRequestRef, [String: JSONLike])
        case reply(MergeRequestRef, discussionID: String, body: String)
        case resolve(MergeRequestRef, discussionID: String, resolved: Bool)
        case retry(MergeRequestRef, jobID: Int)
        case play(MergeRequestRef, jobID: Int)
    }

    var sessionID: SessionID
    var action: Action
    /// The head SHA the card showed (MR actions): applying refuses when the MR moved since.
    var sha: String?
    var summary: String
    var digest: String
}
