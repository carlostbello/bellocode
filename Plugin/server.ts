// BelloCode's opencode server plugin (docs/features/orchestration.md).
//
// Loaded by local path from BelloCode's isolated opencode config (`OPENCODE_CONFIG_CONTENT`), so it needs no npm install
// and no network. It imports nothing from opencode: tool inputs are plain JSON Schema and the context is used through
// the documented promise API (`@opencode/plugin`, 2.3.0), so a type mismatch shows up as a runtime error in the tool
// result, never a load failure. Results carry `content` and `metadata` only: 2.3.0 rejects `output` without a declared
// output schema ("Tool result declared output without an output schema", seen on the real binary). Everything here runs in the server process and keeps working while the app is closed.
//
// Durable state lives in opencode itself: child sessions (`parentID`), session metadata (`metadata.bellocode`) and
// instruction entries. The plugin keeps only short-lived, in-memory bookkeeping (cascades in progress, event dedupe).

import * as L from "./src/logic.ts"
import * as C from "./src/container.ts"
import { readFileSync } from "fs"

type Ctx = any
type ToolContext = {
  readonly sessionID: string
  readonly agent: string
  readonly messageID: string
  readonly id: string
  readonly signal: AbortSignal
  readonly progress: (update: Record<string, unknown>) => Promise<void>
}
type Session = L.SessionLike

const GUIDANCE_KEY = "bellocode.orchestration"

// Shared by every location's instance (one module): dedupe of events seen by several instances, cascades in progress.
const seenEvents = new Set<string>()
const cascading = new Map<string, number>()
const guided = new Set<string>()
const CASCADE_WINDOW_MS = 15_000

function remember(id: string | undefined): boolean {
  if (!id) return true
  if (seenEvents.has(id)) return false
  seenEvents.add(id)
  if (seenEvents.size > 4_000) {
    const first = seenEvents.values().next().value
    if (first !== undefined) seenEvents.delete(first)
  }
  return true
}

function obj(properties: Record<string, unknown>, required: string[] = []) {
  return { type: "object", properties, required, additionalProperties: false }
}
const str = (description: string) => ({ type: "string", description })
const num = (description: string) => ({ type: "number", description })
const bool = (description: string) => ({ type: "boolean", description })
const oneOf = (values: string[], description: string) => ({ type: "string", enum: values, description })

function fail(message: string): never {
  throw new Error(message)
}

function list<T>(value: any): T[] {
  if (Array.isArray(value)) return value as T[]
  if (value && Array.isArray(value.data)) return value.data as T[]
  return []
}

function sleep(ms: number, signal?: AbortSignal) {
  return new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms)
    signal?.addEventListener("abort", () => {
      clearTimeout(timer)
      resolve()
    })
  })
}

export default {
  id: "bellocode",
  setup: async (ctx: Ctx) => {
    const limits = L.limitsFrom(ctx.options)

    // MARK: Container guard (docs/features/containers.md)
    // opencode's shell is already BelloCode's helper (config `shell` and $SHELL); this hook forces it for every shell
    // job (agent tool, /api/shell, terminals through the Shell service), whatever a session or plugin asked for.
    const container = C.containerOptions(ctx.options)
    let guardInstalled = false
    if (container) {
      await ctx.shell.hook("create.before", (event: any) => {
        event.shell = container.helper
      })
      guardInstalled = true
    }
    const readExecConfig = (): C.ExecConfig | undefined => {
      if (!container) return undefined
      try {
        return JSON.parse(readFileSync(container.config, "utf8")) as C.ExecConfig
      } catch {
        return undefined
      }
    }

    // MARK: Session helpers

    const get = async (sessionID: string): Promise<Session> => {
      try {
        const value = await ctx.session.get({ sessionID })
        return (value?.data ?? value) as Session
      } catch {
        return fail(`Thread not found: ${sessionID}`)
      }
    }

    const ancestors = async (session: Session): Promise<Session[]> => {
      const chain: Session[] = []
      let current = session
      for (let guard = 0; current.parentID && guard < 16; guard++) {
        current = await get(current.parentID)
        chain.push(current)
      }
      return chain
    }

    const children = async (sessionID: string): Promise<Session[]> =>
      list<Session>(await ctx.session.list({ parentID: sessionID, limit: 200 }))

    /** Every descendant, parents before children. */
    const descendants = async (sessionID: string): Promise<Session[]> => {
      const out: Session[] = []
      const queue = [sessionID]
      while (queue.length && out.length < 500) {
        const next = await children(queue.shift() as string)
        out.push(...next)
        queue.push(...next.map((child) => child.id))
      }
      return out
    }

    /** Creates a worktree and returns its directory, or fails (nothing usable was returned). */
    const createWorktree = async (projectID: string, already: { threads: string[]; worktrees: string[] }) => {
      const value = await ctx.worktree.create({ projectID })
      const directory = L.usableDirectory((value?.data ?? value)?.directory)
      if (!directory)
        fail(`opencode created no usable worktree directory, so nothing was started in it.${L.recoveryNote(already)}`)
      return directory
    }

    /** Confirms where a new session runs (moving it there if needed) before anything is prompted. A move may land at a
     *  delivery boundary, so the location is read back a few times. Fails with what was created, for recovery. */
    const placeIn = async (session: Session, directory: string, created: { threads: string[]; worktrees: string[] }) => {
      if (L.isLocatedIn(session, directory)) return
      try {
        await ctx.session.move({ sessionID: session.id, directory })
      } catch (error) {
        fail(`Could not move ${session.id} into worktree ${directory} (${L.oneLine(String((error as any)?.message ?? error), 160)}), so it was not started.${L.recoveryNote(created)}`)
      }
      for (let attempt = 0; attempt < 10; attempt++) {
        if (L.isLocatedIn(await get(session.id), directory)) return
        await sleep(100)
      }
      fail(`${session.id} is not running in worktree ${directory} after the move, so it was not started.${L.recoveryNote(created)}`)
    }

    const messages = async (sessionID: string): Promise<L.MessageLike[]> =>
      list<L.MessageLike>(await ctx.session.context({ sessionID }))

    const invocation = (tool: ToolContext) => ({
      sessionID: tool.sessionID,
      agent: tool.agent,
      source: { type: "tool", messageID: tool.messageID, id: tool.id },
    })

    /** Resolves the target and asks the user (approval card) when it is in another project. */
    const reach = async (tool: ToolContext, threadID: string, action: string) => {
      const caller = await get(tool.sessionID)
      const target = await get(threadID)
      const scope = L.scopeOf(caller, target, await ancestors(target))
      if (scope === "other_project") {
        await ctx.permission.assert({
          ...invocation(tool),
          action: "bellocode_other_project",
          resources: [target.location?.directory ?? target.projectID ?? threadID],
          save: [target.location?.directory ?? target.projectID ?? threadID],
          metadata: { operation: action, threadID },
        })
      }
      return { caller, target, scope }
    }

    const describe = (session: Session, extra: Record<string, unknown> = {}) => {
      const meta = L.belloMeta(session)
      return {
        threadID: session.id,
        title: session.title ?? undefined,
        parentID: session.parentID ?? undefined,
        project: session.location?.directory,
        agent: session.agent ?? undefined,
        model: L.modelLabel(session),
        running: L.isRunning(session),
        outcome: session.outcome ?? undefined,
        kind: meta.kind,
        ...extra,
      }
    }

    /** Interrupts `sessionID`'s running descendants (deepest first) and then the session. */
    const cascadeStop = async (sessionID: string, includeSelf: boolean) => {
      const below = (await descendants(sessionID)).filter(L.isRunning)
      const until = Date.now() + CASCADE_WINDOW_MS
      if (below.length) cascading.set(sessionID, until)
      for (const child of below.reverse()) {
        cascading.set(child.id, until)
        await ctx.session.interrupt({ sessionID: child.id }).catch(() => undefined)
      }
      if (includeSelf) await ctx.session.interrupt({ sessionID }).catch(() => undefined)
      return below.length
    }

    const summaryOf = async (sessionID: string) => L.clip(L.lastReply(await messages(sessionID)), 2_000)

    /** Waits until the thread (and optionally its descendants) stops running, the deadline passes or the call stops. */
    const waitIdle = async (sessionID: string, seconds: number, includeChildren: boolean, signal: AbortSignal) => {
      const deadline = Date.now() + seconds * 1000
      while (!signal.aborted) {
        const session = await get(sessionID)
        const busy = L.isRunning(session) || (includeChildren && (await descendants(sessionID)).some(L.isRunning))
        if (!busy) return { settled: true, session }
        if (Date.now() >= deadline) return { settled: false, session }
        await sleep(Math.min(750, Math.max(50, deadline - Date.now())), signal)
      }
      return { settled: false, session: await get(sessionID) }
    }

    const putGuidance = async (session: Session) => {
      guided.add(session.id)
      if (guided.size > 4_000) guided.delete(guided.values().next().value as string)
      const depth = L.depthOf([session, ...(await ancestors(session))])
      const value = L.guidance({ depth, limits, delegated: Boolean(session.parentID) })
      await ctx.session.instructions.entry.put({ sessionID: session.id, key: GUIDANCE_KEY, value }).catch(() => undefined)
      if (container) {
        // Where commands run: rewritten at each run so it reflects the image and any blocked state.
        const text = C.containerGuidance(readExecConfig(), session.location?.directory)
        await ctx.session.instructions.entry
          .put({ sessionID: session.id, key: C.CONTAINER_GUIDANCE_KEY, value: text })
          .catch(() => undefined)
      }
    }

    // MARK: Tools

    const tools: Array<Record<string, unknown>> = [
      {
        name: "orchestrator_capabilities",
        description:
          "List the agents and models you can delegate to, and the orchestration limits (depth, parallel children, threads per call, wait time).",
        input: obj({}),
        execute: async () => {
          const agents = list<any>(await ctx.agent.list({}))
            .filter((agent) => agent.mode !== "primary" && !agent.hidden)
            .map((agent) => ({ id: agent.id, description: L.oneLine(agent.description ?? "", 160) }))
          const models = list<any>(await ctx.model.list({}))
            .filter((model) => (model.type ?? "chat") === "chat" && model.enabled !== false)
            .slice(0, 60)
            .map((model) => ({
              model: `${model.providerID}/${model.id}`,
              variants: (model.variants ?? []).map((variant: any) => variant.id),
            }))
          const output = { agents, models, limits }
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "delegate_task",
        description: [
          "Start a child agent on a self-contained task in a child thread. It starts with no history: put all needed context in `task`.",
          "Returns at once with a taskID (unless wait is set). You are woken with a <subagent> report when it finishes: do not poll or sleep.",
          "Use for parallel or isolated work; small tasks are faster done yourself. Follow up with thread_send to the taskID.",
        ].join(" "),
        input: obj(
          {
            task: str("The full task, with every piece of context the child needs."),
            description: str("A 3-6 word label shown to the user."),
            agent: str("Sub-agent to run (see orchestrator_capabilities). Default: general."),
            model: str('Only when the user asks for a model: "providerID/modelID" or "providerID/modelID#variant".'),
            variant: str("Model variant (reasoning effort), if the model has variants."),
            workspace: oneOf(["shared", "worktree"], "shared (default): this checkout. worktree: a new git worktree, for edits that must not collide."),
            wait: num("Seconds to wait for the result before returning (0 = return at once; capped)."),
          },
          ["task", "description"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const caller = await get(tool.sessionID)
          const chain = [caller, ...(await ancestors(caller))]
          const running = (await children(caller.id)).filter(L.isRunning).length
          const refusal = L.checkDelegate({ callerDepth: L.depthOf(chain), activeChildren: running, limits })
          if (refusal) fail(refusal)
          const agentID = (input.agent as string | undefined)?.trim() || "general"
          const agent = list<any>(await ctx.agent.list({})).find((item) => item.id === agentID)
          if (!agent) fail(`Unknown agent "${agentID}". Call orchestrator_capabilities for the list.`)
          if (agent.mode === "primary") fail(`Agent "${agentID}" is a primary agent and cannot run as a child task.`)
          await ctx.permission.assert({ ...invocation(tool), action: "subagent", resources: [agentID], save: [agentID] })
          const parsed = L.parseModel(input.model, input.variant)
          if (parsed && "error" in parsed) fail(parsed.error)
          const model = parsed ?? agent.model ?? caller.model ?? undefined
          let directory: string | undefined
          const made = { threads: [] as string[], worktrees: [] as string[] }
          if (input.workspace === "worktree") {
            if (!caller.projectID) fail("This thread has no project, so it cannot get a worktree.")
            directory = await createWorktree(caller.projectID, made)
            made.worktrees.push(directory)
          }
          const description = L.oneLine(String(input.description), 80)
          const created = await ctx.session.create({
            parentID: caller.id,
            title: description,
            agent: agentID,
            ...(model ? { model } : {}),
            metadata: {
              bellocode: {
                kind: "delegated",
                by: caller.id,
                description,
                workspace: directory ? "worktree" : "shared",
              } satisfies L.BelloMeta,
            },
          })
          const child = (created?.data ?? created) as Session
          made.threads.push(child.id)
          // The child is prompted only once it is confirmed in its worktree (never silently in this checkout).
          if (directory) await placeIn(child, directory, made)
          await tool.progress({ sessionID: child.id, status: "running", agent: agentID })
          await putGuidance(child)
          await ctx.session.prompt({
            sessionID: child.id,
            text: [
              "You are a delegated child task started by another BelloCode thread. Work only on this task.",
              "Finish with a concise final message: it is reported to the thread that started you.",
              "",
              String(input.task),
            ].join("\n"),
          })
          const seconds = L.clampWait(Number(input.wait ?? 0), limits)
          if (seconds > 0) {
            const waited = await waitIdle(child.id, seconds, true, tool.signal)
            if (waited.settled) {
              const state = L.taskState(waited.session, await children(child.id))
              const summary = await summaryOf(child.id)
              return {
                content: `Task ${child.id} ${state}.\n\n${summary}\n\n(The same result also arrives as a <subagent> report; do not act on it twice.)`,
                metadata: { sessionID: child.id, status: state, agent: agentID },
              }
            }
          }
          return {
            content: [
              `Started task ${child.id} (${agentID}${directory ? `, worktree ${directory}` : ""}).`,
              "You will receive a <subagent> report when it finishes. Do not poll, sleep or duplicate its work.",
              "Work on something else or end your turn.",
            ].join(" "),
            metadata: { sessionID: child.id, status: "running", agent: agentID },
          }
        },
      },
      {
        name: "task_status",
        description:
          "Read a delegated task's state (working, waiting_for_children, result_available, failed, cancelled) and its latest result.",
        input: obj({ taskID: str("The taskID delegate_task returned.") }, ["taskID"]),
        execute: async (input: any, tool: ToolContext) => {
          const { target } = await reach(tool, String(input.taskID), "task_status")
          const below = await children(target.id)
          const state = L.taskState(target, below)
          const summary = state === "working" ? "" : await summaryOf(target.id)
          const output = describe(target, {
            state,
            summary,
            children: { total: below.length, running: below.filter(L.isRunning).length },
          })
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "task_cancel",
        description: "Stop a delegated task and everything it started. Its parent receives a cancelled report.",
        input: obj({ taskID: str("The taskID to stop.") }, ["taskID"]),
        execute: async (input: any, tool: ToolContext) => {
          const { target, scope } = await reach(tool, String(input.taskID), "task_cancel")
          if (scope !== "descendant") fail("task_cancel stops your own child tasks. Use thread_interrupt for other threads.")
          const stopped = await cascadeStop(target.id, true)
          return { content: `Stopped ${target.id}${stopped ? ` and ${stopped} task(s) below it` : ""}.` }
        },
      },
      {
        name: "create_threads",
        description:
          "Create 1 or more new top-level threads in this project (shown in the user's sidebar as a group), optionally each in a new git worktree and started with a prompt.",
        input: obj(
          {
            threads: {
              type: "array",
              minItems: 1,
              items: obj(
                {
                  title: str("Thread title."),
                  prompt: str("First prompt; omit to create an empty thread."),
                  agent: str("Primary agent (build or plan). Default: build."),
                  model: str('"providerID/modelID" or "providerID/modelID#variant".'),
                },
                ["title"],
              ),
            },
            workspace: oneOf(["shared", "worktree"], "shared (default) or one new worktree per thread."),
            background: bool("Start without taking the user's focus (default true)."),
          },
          ["threads"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const caller = await get(tool.sessionID)
          const specs = Array.isArray(input.threads) ? input.threads : []
          const refusal = L.checkCreate(specs.length, limits)
          if (refusal) fail(refusal)
          const group = `grp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`
          const created: Array<Record<string, unknown>> = []
          const isolated = input.workspace === "worktree"
          if (isolated && !caller.projectID) fail("This thread has no project, so it cannot create worktrees.")
          for (const spec of specs) {
            const parsed = L.parseModel(spec.model)
            if (parsed && "error" in parsed) fail(parsed.error)
          }
          // Earlier threads of this call are reported (with their worktrees) if a later one cannot be placed.
          const made = { threads: [] as string[], worktrees: [] as string[] }
          for (const spec of specs) {
            const parsed = L.parseModel(spec.model)
            let directory = caller.location?.directory
            if (isolated) {
              directory = await createWorktree(caller.projectID as string, made)
              made.worktrees.push(directory)
            }
            const value = await ctx.session.create({
              title: L.oneLine(String(spec.title), 100),
              ...(spec.agent ? { agent: spec.agent } : {}),
              ...(parsed ? { model: parsed } : {}),
              ...(directory ? { location: { directory } } : {}),
              metadata: {
                bellocode: {
                  kind: "created",
                  by: caller.id,
                  group,
                  workspace: input.workspace === "worktree" ? "worktree" : "shared",
                  background: input.background !== false,
                } satisfies L.BelloMeta,
              },
            })
            const session = (value?.data ?? value) as Session
            made.threads.push(session.id)
            if (isolated && directory) await placeIn(session, directory, made)
            await putGuidance(session)
            if (spec.prompt) await ctx.session.prompt({ sessionID: session.id, text: String(spec.prompt) })
            created.push({ threadID: session.id, title: session.title, started: Boolean(spec.prompt), directory })
          }
          return {
            content: `Created ${created.length} thread(s):\n${created.map((item) => `- ${item.threadID} ${item.title}`).join("\n")}`,
            metadata: { group, threadIDs: created.map((item) => item.threadID) },
          }
        },
      },
      {
        name: "thread_list",
        description: "List threads: this project's (default) or all projects', newest first, with their state.",
        input: obj({
          scope: oneOf(["project", "all"], "project (default) or all."),
          includeChildren: bool("Include child tasks (default false)."),
          running: bool("Only running threads."),
          limit: num("At most this many (default 20, max 50)."),
        }),
        execute: async (input: any, tool: ToolContext) => {
          const caller = await get(tool.sessionID)
          const limit = Math.min(50, Math.max(1, Number(input.limit ?? 20)))
          const query: Record<string, unknown> = { limit: 200 }
          if (input.scope !== "all" && caller.projectID) query.project = caller.projectID
          let sessions = list<Session>(await ctx.session.list(query))
          if (!input.includeChildren) sessions = sessions.filter((session) => !session.parentID)
          if (input.running) sessions = sessions.filter(L.isRunning)
          const output = sessions.slice(0, limit).map((session) => describe(session))
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "thread_search",
        description: "Search thread titles across projects.",
        input: obj({ query: str("Words in the title."), limit: num("Default 10, max 50.") }, ["query"]),
        execute: async (input: any) => {
          const limit = Math.min(50, Math.max(1, Number(input.limit ?? 10)))
          const output = list<Session>(await ctx.session.list({ search: String(input.query), limit })).map((session) =>
            describe(session),
          )
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "project_list",
        description: "List the projects that have threads, with their directories and thread counts.",
        input: obj({}),
        execute: async () => {
          const sessions = list<Session>(await ctx.session.list({ limit: 500 }))
          const byProject = new Map<string, { project: string; directory?: string; threads: number; running: number }>()
          for (const session of sessions) {
            const key = session.projectID ?? "global"
            const entry = byProject.get(key) ?? { project: key, directory: session.location?.directory, threads: 0, running: 0 }
            entry.threads += 1
            if (L.isRunning(session)) entry.running += 1
            byProject.set(key, entry)
          }
          const output = [...byProject.values()]
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "thread_read",
        description: `Read another thread's recent transcript as text (newest messages, bounded to ${limits.readMaxChars} characters).`,
        input: obj(
          {
            threadID: str("Thread to read."),
            maxMessages: num(`At most this many messages (max ${limits.readMaxMessages}).`),
          },
          ["threadID"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const { target } = await reach(tool, String(input.threadID), "thread_read")
          const rendered = L.renderTranscript(await messages(target.id), {
            maxMessages: Math.min(limits.readMaxMessages, Math.max(1, Number(input.maxMessages ?? limits.readMaxMessages))),
            maxChars: limits.readMaxChars,
          })
          const header = JSON.stringify(describe(target, { truncated: rendered.truncated }))
          return { content: `${header}\n\n${rendered.text || "(no messages)"}` }
        },
      },
      {
        name: "thread_send",
        description:
          "Send a message to another thread (or a follow-up to your child task). It is marked as coming from this thread. queue waits until the thread is idle; steer joins its current run.",
        input: obj(
          {
            threadID: str("Target thread or taskID."),
            message: str("The message."),
            delivery: oneOf(["queue", "steer"], "queue (default) or steer."),
          },
          ["threadID", "message"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const { caller, target, scope } = await reach(tool, String(input.threadID), "thread_send")
          if (scope === "self") fail("That is this thread. Answer directly instead.")
          const from = scope === "descendant" ? "your parent thread" : `thread "${caller.title ?? caller.id}" (${caller.id})`
          const delivery = input.delivery === "steer" ? "steer" : "queue"
          await ctx.session.prompt({
            sessionID: target.id,
            text: `[Message from ${from}]\n${String(input.message)}`,
            delivery,
          })
          return { content: `Sent to ${target.id} (${delivery}).`, metadata: { threadID: target.id } }
        },
      },
      {
        name: "thread_wait",
        description: `Wait (at most ${limits.maxWaitSeconds} s) until another thread finishes its run, then return its state and latest reply. Prefer being woken by <subagent> reports for your own child tasks.`,
        input: obj(
          {
            threadID: str("Thread to wait for."),
            timeoutSeconds: num(`Seconds (max ${limits.maxWaitSeconds}).`),
            includeChildren: bool("Also wait for its child tasks (default true)."),
          },
          ["threadID"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const { target } = await reach(tool, String(input.threadID), "thread_wait")
          const seconds = L.clampWait(Number(input.timeoutSeconds ?? limits.maxWaitSeconds), limits)
          const waited = await waitIdle(target.id, seconds, input.includeChildren !== false, tool.signal)
          const state = L.taskState(waited.session, await children(target.id))
          const summary = waited.settled ? await summaryOf(target.id) : ""
          const output = describe(waited.session, { settled: waited.settled, state, summary })
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "thread_interrupt",
        description: "Stop another thread's current run and its child tasks. Needs the user's approval unless it is your own child task.",
        input: obj({ threadID: str("Thread to stop.") }, ["threadID"]),
        execute: async (input: any, tool: ToolContext) => {
          const { target, scope } = await reach(tool, String(input.threadID), "thread_interrupt")
          if (scope === "self") fail("Use your own final message to stop; you cannot interrupt yourself.")
          if (scope === "same_project")
            await ctx.permission.assert({
              ...invocation(tool),
              action: "bellocode_interrupt",
              resources: [target.id],
              metadata: { title: target.title ?? target.id },
            })
          const stopped = await cascadeStop(target.id, true)
          return { content: `Stopped ${target.id}${stopped ? ` and ${stopped} task(s) below it` : ""}.` }
        },
      },
      {
        name: "pending_requests",
        description:
          "List approvals waiting in this thread and its child tasks, or deny one of a child task's requests with a reason. Agents can never approve: the user does.",
        input: obj({
          action: oneOf(["list", "deny"], "list (default) or deny."),
          requestID: str("For deny: the request ID."),
          threadID: str("For deny: the child thread that raised it."),
          reason: str("For deny: why, shown to the child."),
        }),
        execute: async (input: any, tool: ToolContext) => {
          const caller = await get(tool.sessionID)
          const scope = [caller, ...(await descendants(caller.id))]
          if (input.action === "deny") {
            const threadID = String(input.threadID ?? "")
            if (!scope.some((session) => session.id === threadID && session.id !== caller.id))
              fail("You can only deny requests raised by your own child tasks.")
            await ctx.permission.reply({
              sessionID: threadID,
              requestID: String(input.requestID ?? ""),
              decision: "reject",
              message: L.clip(String(input.reason ?? "Denied by the parent task."), 500),
            })
            return { content: `Denied ${input.requestID}.` }
          }
          const pending: Array<Record<string, unknown>> = []
          for (const session of scope) {
            for (const request of list<any>(await ctx.permission.list({ sessionID: session.id }).catch(() => [])))
              pending.push({
                requestID: request.id,
                threadID: session.id,
                thread: session.title,
                action: request.action,
                resources: (request.resources ?? []).slice(0, 5),
              })
          }
          return { content: pending.length ? JSON.stringify(pending, null, 1) : "Nothing is waiting." }
        },
      },
      {
        name: "send_to_user",
        description:
          "Show the user Markdown they must read now, as a card in this thread (a draft, a decision you need, a summary). Do not repeat it in your reply.",
        input: obj({ markdown: str("The content, Markdown."), title: str("Optional short title.") }, ["markdown"]),
        execute: async (input: any) => {
          const markdown = String(input.markdown ?? "")
          if (!markdown.trim()) fail("Nothing to show: markdown is empty.")
          if (markdown.length > 20_000) fail("Too long for a card (20,000 characters at most). Summarise it.")
          return { content: "Shown to the user.", metadata: { title: input.title ?? null, length: markdown.length } }
        },
      },
    ]

    await ctx.tool.transform((editor: any) => {
      for (const tool of tools) editor.add({ ...tool, options: { codemode: false } })
      // The app's client-MCP tools (`bellocode_app_*`: schedules, PRs, secrets, visuals) are called directly, not through
      // Code Mode's `execute`, so each call is its own transcript row (a visual card, a secret request). Applied on every
      // replay of the transforms, so tools that attach later (the app connects after the server starts) are covered.
      for (const tool of list<any>(editor.list?.() ?? [])) {
        if (L.isAppTool(tool)) editor.update?.(tool.id, (draft: any) => {
          draft.options = { ...(draft.options ?? {}), codemode: false }
        })
      }
    })

    // MARK: RPC (Swift app → plugin)

    const rpc = await ctx.rpc.register(
      {
        id: "bellocode",
        methods: {
          info: { input: { type: "object" }, output: { type: "object" } },
        },
        events: {},
      },
      {
        info: async () => ({
          contract: L.CONTRACT_VERSION,
          plugin: "bellocode",
          location: ctx.location?.directory ?? null,
          limits,
          tools: list<any>(await ctx.tool.list())
            .map((tool) => tool.id ?? tool.name)
            .filter((name: string) => tools.some((item) => item.name === name)),
          container: container ? { guard: guardInstalled, helper: container.helper } : null,
          appTools: list<any>(await ctx.tool.list())
            .filter(L.isAppTool)
            .map((tool) => ({ id: tool.id ?? tool.name, codemode: tool.options?.codemode !== false })),
        }),
      },
    )

    // MARK: Events: cascade stops, summaries, guidance

    let stopped = false
    const stream = ctx.event.subscribe({
      types: [
        "session.created",
        "session.execution.started",
        "session.execution.succeeded",
        "session.execution.failed",
        "session.execution.interrupted",
      ],
    })
    const iterator = stream[Symbol.asyncIterator]()

    const onSettled = async (sessionID: string, outcome: string) => {
      const session = await get(sessionID)
      if (!session.parentID && !L.belloMeta(session).kind) return
      const summary = L.oneLine(L.lastReply(await messages(sessionID)), 280)
      const metadata = { ...(session.metadata ?? {}) }
      metadata.bellocode = { ...L.belloMeta(session), summary, outcome, settledAt: Date.now() }
      await ctx.session.update({ sessionID, metadata })
    }

    const handle = async (event: any) => {
      if (!remember(event?.id)) return
      const sessionID = event?.data?.sessionID as string | undefined
      if (!sessionID) return
      switch (event.type) {
        case "session.created":
          await putGuidance(await get(sessionID))
          return
        case "session.execution.started": {
          // Sessions created before the plugin (or while it reloaded) get their guidance at their next run; with
          // containers, every run refreshes it (image, tools, blocked state).
          if (!guided.has(sessionID) || container) await putGuidance(await get(sessionID)).catch(() => undefined)
          // A child's cancelled report wakes its parent; inside a cascade window that restart is cut at once.
          const until = cascading.get(sessionID)
          if (until && until > Date.now()) await ctx.session.interrupt({ sessionID }).catch(() => undefined)
          else if (until) cascading.delete(sessionID)
          return
        }
        case "session.execution.interrupted":
          if (event.data.reason === "user") await cascadeStop(sessionID, false)
          await onSettled(sessionID, "interrupted")
          return
        case "session.execution.succeeded":
          await onSettled(sessionID, "succeeded")
          return
        case "session.execution.failed":
          await onSettled(sessionID, "failed")
          return
      }
    }

    void (async () => {
      while (!stopped) {
        let next: IteratorResult<any>
        try {
          next = await iterator.next()
        } catch {
          return
        }
        if (next.done) return
        handle(next.value).catch(() => undefined)
      }
    })()

    return async () => {
      stopped = true
      await iterator.return?.().catch?.(() => undefined)
      await rpc?.dispose?.().catch?.(() => undefined)
    }
  },
}
