// Pure orchestration rules for the bellocode opencode plugin. No opencode imports, so `bun test` runs them directly.
//
// The plugin works on opencode's own session JSON (the shape `GET /api/session/{id}` returns): child sessions have a
// `parentID`, `time.busy`/`time.idle` give the run state, and `metadata.bellocode` holds what BelloCode adds.

export const CONTRACT_VERSION = 1

export interface Limits {
  /** Deepest delegation below a top-level thread (a child of a top-level thread has depth 1). */
  readonly maxDepth: number
  /** Children of one session that may run at the same time. */
  readonly maxActiveChildren: number
  /** Threads one `create_threads` call may create. */
  readonly maxCreate: number
  /** Longest a tool may wait for another thread before returning. */
  readonly maxWaitSeconds: number
  /** Messages and characters `thread_read` returns at most. */
  readonly readMaxMessages: number
  readonly readMaxChars: number
}

export const DEFAULT_LIMITS: Limits = {
  maxDepth: 2,
  maxActiveChildren: 6,
  maxCreate: 8,
  maxWaitSeconds: 45,
  readMaxMessages: 20,
  readMaxChars: 12_000,
}

export function limitsFrom(options: unknown): Limits {
  const value = (options && typeof options === "object" ? (options as Record<string, unknown>).limits : undefined) as
    | Record<string, unknown>
    | undefined
  const pick = (key: keyof Limits, min: number, max: number) => {
    const raw = value?.[key]
    if (typeof raw !== "number" || !Number.isFinite(raw)) return DEFAULT_LIMITS[key]
    return Math.min(max, Math.max(min, Math.floor(raw)))
  }
  return {
    maxDepth: pick("maxDepth", 1, 5),
    maxActiveChildren: pick("maxActiveChildren", 1, 20),
    maxCreate: pick("maxCreate", 1, 20),
    maxWaitSeconds: pick("maxWaitSeconds", 1, 300),
    readMaxMessages: pick("readMaxMessages", 1, 100),
    readMaxChars: pick("readMaxChars", 500, 100_000),
  }
}

// MARK: - Sessions

export interface SessionLike {
  readonly id: string
  readonly parentID?: string | null
  readonly projectID?: string
  readonly title?: string | null
  readonly agent?: string | null
  readonly model?: { readonly id?: string; readonly providerID?: string; readonly variant?: string | null } | null
  readonly outcome?: string | null
  readonly time?: { readonly created?: number; readonly busy?: number | null; readonly idle?: number | null }
  readonly metadata?: Record<string, unknown> | null
  readonly location?: { readonly directory?: string } | null
}

/** What BelloCode records on a session it created (`metadata.bellocode`). */
export interface BelloMeta {
  /** `delegated`: a child task from `delegate_task`; `created`: a top-level thread from `create_threads`. */
  kind?: "delegated" | "created"
  /** The session whose tool call created this one. */
  by?: string
  /** Threads created by one `create_threads` call share a group. */
  group?: string
  description?: string
  workspace?: "shared" | "worktree"
  background?: boolean
  /** Short summary of the last finished round (set when a child settles). */
  summary?: string
  outcome?: string
  settledAt?: number
}

export function belloMeta(session: SessionLike): BelloMeta {
  const raw = session.metadata?.bellocode
  return raw && typeof raw === "object" ? (raw as BelloMeta) : {}
}

export function isRunning(session: SessionLike): boolean {
  const busy = session.time?.busy
  if (busy == null) return false
  const idle = session.time?.idle
  return idle == null || busy > idle
}

export function modelLabel(session: SessionLike): string | undefined {
  const model = session.model
  if (!model?.providerID || !model.id) return undefined
  return `${model.providerID}/${model.id}${model.variant ? `#${model.variant}` : ""}`
}

/** `providerID/modelID` or `providerID/modelID#variant`, with an optional separate variant. */
export function parseModel(
  value: string | undefined,
  variant?: string,
): { providerID: string; id: string; variant?: string } | { error: string } | undefined {
  if (!value) return variant ? { error: "A variant needs a model: pass model as providerID/modelID." } : undefined
  const [ref, inlineVariant] = value.split("#", 2)
  const slash = ref.indexOf("/")
  if (slash <= 0 || slash === ref.length - 1)
    return { error: `Invalid model "${value}". Use "providerID/modelID" or "providerID/modelID#variant".` }
  const chosen = variant ?? inlineVariant
  return { providerID: ref.slice(0, slash), id: ref.slice(slash + 1), ...(chosen ? { variant: chosen } : {}) }
}

/** Depth below the top-level thread: `chain` is the caller followed by its ancestors (top-level last). */
export function depthOf(chain: readonly SessionLike[]): number {
  return Math.max(0, chain.length - 1)
}

export function checkDelegate(input: {
  readonly callerDepth: number
  readonly activeChildren: number
  readonly limits: Limits
}): string | undefined {
  if (input.callerDepth + 1 > input.limits.maxDepth)
    return `Delegation depth limit reached: this thread is ${input.callerDepth} level(s) below a top-level thread and the limit is ${input.limits.maxDepth}. Do the work yourself or report back to your parent.`
  if (input.activeChildren >= input.limits.maxActiveChildren)
    return `Too many running child tasks (${input.activeChildren} of ${input.limits.maxActiveChildren}). Wait for one to finish (you are woken when it does) or cancel one with task_cancel.`
  return undefined
}

export function checkCreate(count: number, limits: Limits): string | undefined {
  if (count < 1) return "Give at least one thread."
  if (count > limits.maxCreate) return `At most ${limits.maxCreate} threads per call (got ${count}).`
  return undefined
}

export function clampWait(seconds: number | undefined, limits: Limits): number {
  if (seconds == null || !Number.isFinite(seconds)) return limits.maxWaitSeconds
  return Math.min(limits.maxWaitSeconds, Math.max(0, seconds))
}

// MARK: - Task state

export type TaskState = "working" | "waiting_for_children" | "result_available" | "failed" | "cancelled" | "idle"

/** A delegated task's state as `task_status` reports it (T3 Code's work states, plus failure and cancellation). */
export function taskState(session: SessionLike, children: readonly SessionLike[]): TaskState {
  if (isRunning(session)) return "working"
  if (children.some(isRunning)) return "waiting_for_children"
  if (session.outcome === "failed") return "failed"
  if (session.outcome === "interrupted") return "cancelled"
  if (session.outcome === "succeeded") return "result_available"
  return "idle"
}

// MARK: - Scoping

export type Scope = "self" | "descendant" | "same_project" | "other_project"

/**
 * How `target` relates to `caller`. `ancestors(target)` is the target's ancestor chain (parent first). Agents act freely
 * on their own descendants and on threads of their own project; other projects need the user's approval.
 */
export function scopeOf(caller: SessionLike, target: SessionLike, targetAncestors: readonly SessionLike[]): Scope {
  if (caller.id === target.id) return "self"
  if (targetAncestors.some((ancestor) => ancestor.id === caller.id)) return "descendant"
  if (caller.projectID && caller.projectID === target.projectID) return "same_project"
  return "other_project"
}

// MARK: - Text

export function clip(text: string, max: number): string {
  const clean = text.trim()
  if (clean.length <= max) return clean
  return clean.slice(0, Math.max(0, max - 1)).trimEnd() + "…"
}

/** One line for lists: whitespace collapsed. */
export function oneLine(text: string, max: number): string {
  return clip(text.replace(/\s+/g, " "), max)
}

export interface MessageLike {
  readonly type: string
  readonly text?: string
  readonly content?: ReadonlyArray<{ readonly type: string; readonly text?: string; readonly name?: string }>
}

export function assistantText(message: MessageLike): string {
  if (message.type !== "assistant") return ""
  return (message.content ?? [])
    .filter((part) => part.type === "text" && part.text)
    .map((part) => part.text as string)
    .join("\n\n")
}

/** The text of the last assistant message that has any, for summaries. */
export function lastReply(messages: readonly MessageLike[]): string {
  for (let index = messages.length - 1; index >= 0; index--) {
    const text = assistantText(messages[index])
    if (text.trim()) return text
  }
  return ""
}

/**
 * A bounded plain-text transcript, newest messages kept: at most `maxMessages` messages and `maxChars` characters.
 * Tool calls are listed by name only (their inputs and outputs can be large and private to that thread).
 */
export function renderTranscript(
  messages: readonly MessageLike[],
  options: { readonly maxMessages: number; readonly maxChars: number },
): { text: string; truncated: boolean } {
  const lines: string[] = []
  for (const message of messages) {
    if (message.type === "user" || message.type === "synthetic") {
      if (message.text) lines.push(`[${message.type}] ${message.text}`)
    } else if (message.type === "assistant") {
      const tools = (message.content ?? []).filter((part) => part.type === "tool").map((part) => part.name ?? "tool")
      const text = assistantText(message)
      if (text) lines.push(`[assistant] ${text}`)
      if (tools.length) lines.push(`[tools] ${tools.join(", ")}`)
    }
  }
  let kept = lines.slice(-options.maxMessages)
  let truncated = kept.length < lines.length
  let text = kept.join("\n\n")
  if (text.length > options.maxChars) {
    text = "…" + text.slice(text.length - options.maxChars + 1)
    truncated = true
  }
  return { text, truncated }
}

/** The instruction entry every session gets (`bellocode.orchestration`). Short: the tool descriptions carry details. */
/** A client-MCP tool of the BelloCode app (namespace `bellocode_app`). */
export function isAppTool(tool: { id?: string; name?: string; options?: { namespace?: string } }): boolean {
  if (tool.options?.namespace === "bellocode_app") return true
  return typeof tool.id === "string" && tool.id.startsWith("bellocode_app_")
}

/** The app's own tools (`bellocode_app_*`, present while BelloCode runs): one line each, kept short. */
export const extrasGuidance = [
  "While the BelloCode app runs it also offers bellocode_app_* tools:",
  "- schedule_task / list_scheduled_tasks / update_scheduled_task / delete_scheduled_task / run_scheduled_task_now: recurring or later prompts (a new thread per run, or this thread). New ones and your changes may wait for the user's approval.",
  "- link_merge_requests / watch_merge_request: link GitLab merge requests (URL or !iid; the branch's open MR is linked automatically); a watched MR wakes you once per event (pipeline done, approval, comments, merged/closed). Never poll an MR. No glab or gh.",
  "- request_secret asks the user for a token in a private card, then end your turn; pass the one-use secretRef to secret_exec with the one command that needs it (the user approves that command). Never ask for or print secrets.",
  "- html_render shows a chart or rich visual inline (self-contained HTML, theme CSS variables, no network unless approved); html_preview checks it first and gives a PNG.",
]

export function guidance(input: { readonly depth: number; readonly limits: Limits; readonly delegated: boolean }): string {
  const canDelegate = input.depth + 1 <= input.limits.maxDepth
  const lines = [
    "BelloCode orchestration tools are available.",
    canDelegate
      ? "- delegate_task starts a child agent on a self-contained task (give it all context). You are woken with a <subagent> report when it finishes: do not poll, sleep or wait in a loop. task_status / task_cancel manage it; thread_send to the child sends a follow-up."
      : "- You cannot delegate further (depth limit). Do the work yourself.",
    "- create_threads fans work out into new top-level threads the user sees in the sidebar.",
    "- thread_list, thread_search, thread_read, thread_send, thread_wait, thread_interrupt work with other threads of this project; other projects need the user's approval.",
    "- send_to_user shows the user something they must read now (a draft, a decision, a summary).",
    "Use these only when parallel or separate work clearly helps; small tasks are faster done directly.",
    ...extrasGuidance,
  ]
  if (input.delegated)
    lines.push("You are a delegated child task: finish with a concise final message, which is reported to your parent.")
  return lines.join("\n")
}
