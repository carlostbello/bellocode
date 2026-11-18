import BelloCore
import Foundation
import OpenCodeKit

/// The orchestration-extras app tools (client MCP, shown to agents as `bellocode_app_<name>`), docs/features/
/// orchestration-extras.md. Every call is attributed to its session (`_meta`), scoped to the caller's project, and
/// exists only while BelloCode runs (which is also when schedules run and PRs are watched).
public enum ExtrasTools {
    public static let scheduleTask = "schedule_task"
    public static let listScheduledTasks = "list_scheduled_tasks"
    public static let updateScheduledTask = "update_scheduled_task"
    public static let deleteScheduledTask = "delete_scheduled_task"
    public static let runScheduledTaskNow = "run_scheduled_task_now"
    public static let linkMergeRequests = "link_merge_requests"
    public static let unlinkMergeRequests = "unlink_merge_requests"
    public static let listThreadMergeRequests = "list_thread_merge_requests"
    public static let watchMergeRequest = "watch_merge_request"
    public static let unwatchMergeRequest = "unwatch_merge_request"
    public static let requestSecret = "request_secret"
    public static let secretFile = "secret_file"
    /// Containerised projects: runs one command in the project's container with the secret in its environment.
    public static let secretExec = "secret_exec"
    public static let htmlPreview = "html_preview"
    public static let htmlRender = "html_render"

    public static let all = [
        scheduleTask, listScheduledTasks, updateScheduledTask, deleteScheduledTask, runScheduledTaskNow, linkMergeRequests,
        unlinkMergeRequests, listThreadMergeRequests, watchMergeRequest, unwatchMergeRequest, requestSecret, secretFile,
        secretExec, htmlPreview, htmlRender,
    ] + GitLabTools.all + GitPushTool.all

    static func string(_ description: String) -> JSONValue { .object(["type": .string("string"), "description": .string(description)]) }
    static func number(_ description: String) -> JSONValue { .object(["type": .string("number"), "description": .string(description)]) }
    static func boolean(_ description: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(description)]) }
    static func strings(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string))])
    }

    static let scheduleFields: [String: JSONValue] = [
        "name": string("Short name shown in the Scheduled Tasks list."),
        "prompt": string("What the agent should do each run (self-contained: a new thread starts with no history)."),
        "everyMinutes": number("Run every N minutes (at least 1). Use this, or time, or once."),
        "time": string("Run at this local time of day, \"HH:MM\" (24 h)."),
        "weekdays": strings("With time: days to run, e.g. [\"mon\",\"tue\",\"wed\",\"thu\",\"fri\"]. Omit for every day."),
        "once": string("Run once at this ISO 8601 date-time, e.g. 2026-12-01T09:00:00+01:00."),
        "timeZone": string("IANA time zone for time (default: the user's)."),
        "destination": string("new_thread (default: a new thread per run in this project), this_thread, or a thread ID of this project."),
        "agent": string("Agent for new threads (default: build)."),
        "model": string("\"providerID/modelID\" for new threads."),
        "permissionMode": string("ask, autoEdit or fullAccess; never broader than this thread's own mode."),
        "catchUp": boolean("If missed while BelloCode was quit, run once at the next launch (default true)."),
    ]

    public static let definitions: [ClientMCPTool] = [
        ClientMCPTool(
            name: scheduleTask,
            description:
                "Schedule a prompt to run later or repeatedly while BelloCode is running (missed runs catch up once at launch). The first agent-created task in a project needs the user's approval; until then it is paused.",
            inputSchema: object(scheduleFields, required: ["name", "prompt"])),
        ClientMCPTool(
            name: listScheduledTasks, description: "List this project's scheduled tasks with their next run and last result.",
            inputSchema: object([:])),
        ClientMCPTool(
            name: updateScheduledTask,
            description: "Change a scheduled task an agent created in this project (any field of schedule_task, or enabled).",
            inputSchema: object(scheduleFields.merging(["taskID": string("The task."), "enabled": boolean("Pause (false) or resume (true).")]) { $1 }, required: ["taskID"])),
        ClientMCPTool(
            name: deleteScheduledTask, description: "Delete a scheduled task an agent created in this project.",
            inputSchema: object(["taskID": string("The task.")], required: ["taskID"])),
        ClientMCPTool(
            name: runScheduledTaskNow, description: "Run an approved scheduled task of this project now (its schedule is unchanged).",
            inputSchema: object(["taskID": string("The task.")], required: ["taskID"])),
        ClientMCPTool(
            name: linkMergeRequests,
            description: "Link GitLab merge requests to this thread (shown in the thread header), by URL or as !iid in this project. watch: also wake this thread when its pipeline finishes, approvals change, comments arrive, or it is merged/closed.",
            inputSchema: object(["refs": strings("MR URLs (https://gitlab.example.com/group/project/-/merge_requests/12) or !12 (1-10)."), "watch": boolean("Also watch them.")], required: ["refs"])),
        ClientMCPTool(
            name: unlinkMergeRequests, description: "Unlink merge requests from this thread (stops watching them).",
            inputSchema: object(["refs": strings("MR URLs or !iid.")], required: ["refs"])),
        ClientMCPTool(
            name: listThreadMergeRequests, description: "List this thread's linked merge requests with state, approvals, pipeline and unresolved discussions.",
            inputSchema: object([:])),
        ClientMCPTool(
            name: watchMergeRequest,
            description: "Babysit a merge request: this thread is woken once per event (pipeline failed or passed, with a failing-job log excerpt; new review comments; approval given or revoked; merged or closed), within the user's wake budget. The first time in a project the user approves it on a card. Do not poll.",
            inputSchema: object(["ref": string("MR URL or !iid.")], required: ["ref"])),
        ClientMCPTool(
            name: unwatchMergeRequest, description: "Stop babysitting a merge request (it stays linked).",
            inputSchema: object(["ref": string("MR URL or !iid.")], required: ["ref"])),
        ClientMCPTool(
            name: requestSecret,
            description:
                "Ask the user for a secret (token, password) in a private card. The value is not put in this conversation: when they save it you are woken with a one-use secretRef. In a containerised project, pass it to secret_exec with the one command that needs it; the user approves that exact command before it receives the value. End your turn after calling this.",
            inputSchema: object(
                [
                    "label": string("What it is, e.g. \"npm publish token\"."), "reason": string("Why you need it, one sentence."),
                    "url": string("Optional sign-in or setup page (https) shown as a button."),
                    "delivery": string("reference (default: a one-use secretRef for secret_file) or file (a one-read path at once)."),
                ], required: ["label", "reason"])),
        ClientMCPTool(
            name: secretFile,
            description:
                "Projects without container execution only. Exchange a secretRef (once) for a path that yields the secret to the first process that reads it, then disappears (10 minutes at most). Use it in one command, e.g. --token-file PATH or \"$(cat PATH)\". Never print it.",
            inputSchema: object(["secretRef": string("From the request_secret wake message.")], required: ["secretRef"])),
        ClientMCPTool(
            name: secretExec,
            description:
                "Ask to run one command with a secret in an environment variable. The user sees this exact command and approves it (or not) before it runs; then you are woken with its output. It runs in a throwaway container with no network and a read-only project unless you ask for network or writesProject (shown to the user). Exchange a container secretRef (bcsecretc_…) here. Never print, encode or store the value. End your turn after calling this.",
            inputSchema: object(
                [
                    "secretRef": string("From the request_secret wake message."),
                    "name": string("Environment variable to hold the value, e.g. NPM_TOKEN."),
                    "command": string("Shell command run in the project's folder, e.g. npm publish. Shown verbatim to the user."),
                    "network": boolean("The command needs outbound network (for example to publish). Default false."),
                    "writesProject": boolean("The command must write into the project folder. Default false (read-only)."),
                    "includeMounts": boolean("The command needs the project's extra host folders (Project Settings ▸ Environment mounts). Default false: none are mounted. Each folder and its access is shown to the user."),
                ], required: ["secretRef", "name", "command"])),
        ClientMCPTool(
            name: htmlPreview,
            description:
                "Check an HTML page before showing it: renders it in BelloCode's sandbox and returns its content height, console errors, blocked requests and a PNG path (you may attach or post that PNG elsewhere). Not shown to the user.",
            inputSchema: object(
                [
                    "html": string("A complete, self-contained HTML document."), "path": string("Or an .html file (absolute or relative to this thread's folder)."),
                    "allowNetwork": strings("Host names the page may load from (only already-approved hosts load in previews)."),
                ])),
        ClientMCPTool(
            name: htmlRender,
            description:
                "Show a chart, diagram or rich visual inline in this thread (above your reply). Self-contained HTML; use the CSS variables --background, --foreground, --muted, --border, --accent, --chart-1..--chart-6, --font-sans, --font-mono so it follows light/dark. No network unless allowNetwork hosts are approved by the user. Links open only when the user clicks.",
            inputSchema: object(
                [
                    "html": string("The document."), "path": string("Or an .html file."), "title": string("Short title shown above it."),
                    "allowNetwork": strings("Host names to load from (asks the user)."),
                ], required: ["title"])),
    ] + GitLabTools.definitions + GitPushTool.definitions
}
