// BelloCode Auto mode, Full-access risk instrumentation and attributed interrupts (docs/features/auto-mode.md).
//
// Pure helpers, no opencode imports (bun tests run them directly). The hooks in server.ts call these.
//
// Verified on opencode 2.3.0 and 2.3.2 (same code path in both): `Permission.evaluate` checks the agent + session rules
// for a deny first (a deny returns before any plugin hook runs), then appends the project's saved "always" grants (as
// allow), computes ask/allow and only then triggers the `permission.evaluate` hook with `effect`. The hook may change
// `effect` (and `message`); promise hooks are awaited. So a hook sees saved grants already applied and can turn their
// `allow` back into `ask`; it cannot see, or undo, a configured deny.

/** The marker rule BelloCode puts first in an Auto session's rules (`PermissionModeRules`, Swift). */
export const AUTO_MARKER_ACTION = "bellocode_auto"
/** An action only BelloCode's contract tests evaluate (`POST /api/session/{id}/permission`): the hook waits, then sets
 *  the effect named in `metadata.effect`, to prove promise hooks are awaited. Never asserted by a tool. */
export const PROBE_ACTION = "bellocode_contract_probe"

export type Effect = "allow" | "ask" | "deny"
export type Rule = { readonly action?: string; readonly resource?: string; readonly effect?: string }
export type Mode = "auto" | "full" | "other"

/** The BelloCode mode a session's rules describe (children inherit their parent's rules, so their mode too). */
export function modeOf(rules: readonly Rule[] | null | undefined): Mode {
  if (!rules?.length) return "other"
  if (rules.some((rule) => rule.action === AUTO_MARKER_ACTION)) return "auto"
  const first = rules[0]
  if (first?.action === "*" && first.resource === "*" && first.effect === "allow") return "full"
  return "other"
}

/** What the evaluate hook does to an effect in a session of `mode`. Auto: every `allow` (a saved grant, or a rule) is
 *  turned into `ask`, so BelloCode's policy reviews it; `deny` never reaches the hook. Other modes: unchanged. */
export function autoEffect(mode: Mode, effect: Effect): { effect: Effect; changed: boolean } {
  if (mode === "auto" && effect === "allow") return { effect: "ask", changed: true }
  return { effect, changed: false }
}

export const AUTO_MESSAGE = "BelloCode Auto reviews this request"

// MARK: - Contract trace (no content: names, effects and counts only)

export type TraceEntry = {
  seq: number
  hook: "evaluate" | "execute.before" | "execute.after" | "shell.create.before"
  sessionID?: string
  callID?: string
  tool?: string
  action?: string
  resources?: number
  effectIn?: string
  effectOut?: string
  mode?: Mode
  status?: string
  at: number
}

export class Trace {
  private entries: TraceEntry[] = []
  private seq = 0
  constructor(private readonly limit = 400) {}

  add(entry: Omit<TraceEntry, "seq" | "at">): void {
    this.seq += 1
    this.entries.push({ ...entry, seq: this.seq, at: Date.now() })
    if (this.entries.length > this.limit) this.entries.splice(0, this.entries.length - this.limit)
  }

  list(sessionID?: string): TraceEntry[] {
    return sessionID ? this.entries.filter((entry) => entry.sessionID === sessionID) : [...this.entries]
  }

  clear(): void {
    this.entries = []
  }

  get count(): number {
    return this.seq
  }
}

// MARK: - Per-call permission record (stamped onto the tool result as `metadata.bellocode_permissions`)

export type Evaluated = { action: string; resources: string[]; effect: string }
export const PERMISSIONS_METADATA_KEY = "bellocode_permissions"

/** Bounded map callID → evaluations made during that call (opencode's own canonical resources: paths it classified,
 *  parsed shell commands, URLs). The app's risk detectors read them from the finished tool part. */
export class CallPermissions {
  private map = new Map<string, Evaluated[]>()
  constructor(private readonly calls = 512, private readonly perCall = 12) {}

  record(callID: string | undefined, value: Evaluated): void {
    if (!callID) return
    const list = this.map.get(callID) ?? []
    if (list.length < this.perCall)
      list.push({
        action: value.action.slice(0, 80),
        effect: value.effect,
        resources: value.resources.slice(0, 8).map((resource) => String(resource).slice(0, 300)),
      })
    this.map.delete(callID)
    this.map.set(callID, list)
    while (this.map.size > this.calls) {
      const first = this.map.keys().next().value
      if (first === undefined) break
      this.map.delete(first)
    }
  }

  take(callID: string | undefined): Evaluated[] | undefined {
    if (!callID) return undefined
    const value = this.map.get(callID)
    this.map.delete(callID)
    return value
  }
}

// MARK: - Attributed interrupts (research 08 §5)

export type InterruptLimits = {
  /** Interrupts one caller may make per window. */
  readonly perCaller: number
  /** Interrupts of one target (by any agent) per window. */
  readonly perTarget: number
  readonly windowMs: number
  /** A thread an agent interrupted cannot interrupt others for this long (caps cascades). */
  readonly cascadeMs: number
}

export const DEFAULT_INTERRUPT_LIMITS: InterruptLimits = { perCaller: 3, perTarget: 2, windowMs: 5 * 60_000, cascadeMs: 60_000 }

/** In-memory rate limiter and cascade cap for agent-initiated interrupts (the server process owns it). */
export class InterruptGuard {
  private byCaller = new Map<string, number[]>()
  private byTarget = new Map<string, number[]>()
  private interruptedAt = new Map<string, number>()
  constructor(private readonly limits: InterruptLimits = DEFAULT_INTERRUPT_LIMITS, private readonly now = () => Date.now()) {}

  private recent(map: Map<string, number[]>, key: string): number[] {
    const since = this.now() - this.limits.windowMs
    const list = (map.get(key) ?? []).filter((at) => at > since)
    map.set(key, list)
    return list
  }

  /** A refusal message, or undefined when the interrupt may go ahead (then call `record`). */
  check(caller: string, target: string): string | undefined {
    const hit = this.interruptedAt.get(caller)
    if (hit !== undefined && this.now() - hit < this.limits.cascadeMs)
      return "This thread was itself interrupted by another agent moments ago, so it cannot interrupt other threads yet (cascade limit). Tell the user instead."
    if (this.recent(this.byCaller, caller).length >= this.limits.perCaller)
      return `Rate limit: this thread already interrupted ${this.limits.perCaller} threads in the last ${Math.round(this.limits.windowMs / 60_000)} minutes. Ask the user instead.`
    if (this.recent(this.byTarget, target).length >= this.limits.perTarget)
      return `Rate limit: that thread was already interrupted ${this.limits.perTarget} times in the last ${Math.round(this.limits.windowMs / 60_000)} minutes. Ask the user instead.`
    return undefined
  }

  record(caller: string, target: string): void {
    const at = this.now()
    this.recent(this.byCaller, caller).push(at)
    this.recent(this.byTarget, target).push(at)
    this.interruptedAt.set(target, at)
    if (this.interruptedAt.size > 2_000) this.interruptedAt.delete(this.interruptedAt.keys().next().value as string)
  }
}

/** `metadata.bellocode.interrupt` on the target: who stopped it and why, and that its queued work is held. */
export type InterruptRecord = {
  by: string
  byTitle?: string
  reason: string
  at: number
  requested: string
  actual: "stopped" | "still_running" | "failed" | "not_running"
  held: boolean
}

export const INTERRUPT_NOTE_PREFIX = "[BelloCode interrupt]"

/** The non-waking note posted into the target's transcript (and so its model context). */
export function interruptNote(record: InterruptRecord): string {
  const who = record.byTitle ? `“${record.byTitle}” (${record.by})` : record.by
  return `${INTERRUPT_NOTE_PREFIX} Stopped by thread ${who}: ${record.reason}. Queued work is held until the user resumes this thread.`
}

/** The reason an agent gave, bounded and on one line. A missing reason is refused by the tool. */
export function cleanReason(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const text = value.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return text.length > 200 ? text.slice(0, 199) + "…" : text
}
