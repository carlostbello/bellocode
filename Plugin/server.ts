// BelloCode's opencode server plugin (docs/features/orchestration.md).
//
// Loaded by local path from BelloCode's isolated opencode config (`OPENCODE_CONFIG_CONTENT`), so it needs no npm install
// and no network. It imports nothing from opencode: tool inputs are plain JSON Schema and the context is used through
// the documented promise API (`@opencode/plugin`, 2.3.2 as pinned), so a type mismatch shows up as a runtime error in the tool
// result, never a load failure. Results carry `content` and `metadata` only: opencode rejects `output` without a declared
// output schema ("Tool result declared output without an output schema", seen on the real 2.3.0 binary). Everything here runs in the server process and keeps working while the app is closed.
//
// Durable state lives in opencode itself: child sessions (`parentID`), session metadata (`metadata.bellocode`) and
// instruction entries. The plugin keeps only short-lived, in-memory bookkeeping (cascades in progress, event dedupe).

import * as L from "./src/logic.ts"
import * as C from "./src/container.ts"
import * as A from "./src/auto.ts"
import * as P from "./src/project.ts"
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
/** The repository instruction text last written per session (rewritten only when the files change). */
const projectInstructionsWritten = new Map<string, string>()
const CASCADE_WINDOW_MS = 15_000
/** Session list page size, pages per parent and sessions per tree walk (beyond these a walk reports incomplete). */
const PAGE_SIZE = 200
const CHILD_PAGES = 25
const TREE_LIMIT = 2_000
/** How long a stop reads back interrupted sessions to confirm they settled. */
const CONFIRM_MS = 5_000
const CONFIRM_POLL_MS = 150

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
    const trace = new A.Trace()
    let guardInstalled = false
    if (container) {
      await ctx.shell.hook("create.before", (event: any) => {
        event.shell = container.helper
        trace.add({ hook: "shell.create.before" })
      })
      guardInstalled = true
    } else if (ctx.shell?.hook) {
      await ctx.shell.hook("create.before", () => trace.add({ hook: "shell.create.before" }))
    }
    const readExecConfig = (): C.ExecConfig | undefined => {
      if (!container) return undefined
      try {
        return JSON.parse(readFileSync(container.config, "utf8")) as C.ExecConfig
      } catch {
        return undefined
      }
    }

    // MARK: Repository opencode configuration (docs/features/opencode-config.md)
    // Default ("bellocode") mode: opencode's own project config is off for the whole server. Every session gets its
    // repository's AGENTS.md text as an instruction entry; a trusted project's location also gets the repository's
    // `.opencode/` agents, commands and skills. Transforms only use editor methods verified on 2.3.2 (agent `update`,
    // command and skill `add`) and never throw: a throwing transform disables the whole plugin.
    const projectConfig = P.projectConfigOptions(ctx.options)
    const locationDirectory: string | undefined = ctx.location?.directory
    let projectLoaded: P.Loaded = P.EMPTY
    /** The trust file revision the last refresh read (acknowledged to the app by `bellocode.projectConfig`). */
    let trustRevision = 0
    /** Re-reads the trust file and the repository. Never throws: a hostile or malformed repository must not abort
     * setup, which would also drop the container guard and Auto hooks installed above and below (N01). */
    const refreshProjectConfig = (): boolean => {
      if (projectConfig?.mode !== "bellocode") {
        projectLoaded = P.EMPTY
        return true
      }
      try {
        const trust = P.readTrustFile(projectConfig.trustFile)
        trustRevision = trust.revision
        projectLoaded = P.loadProjectConfig(locationDirectory, trust.trusted)
        return true
      } catch (error) {
        projectLoaded = { ...P.EMPTY, skipped: [`repository configuration not loaded: ${String((error as any)?.message ?? error).slice(0, 200)}`] }
        return false
      }
    }
    /** At run time, a project command still needs its repository trusted (a revocation that failed to replay the
     * transforms must not leave a working command behind). */
    const stillTrusted = (): boolean => {
      try {
        return P.trustedProject(locationDirectory, P.readTrust(projectConfig?.trustFile)) !== undefined
      } catch {
        return false
      }
    }
    if (projectConfig?.mode === "bellocode") {
      // Registration failures leave repository configuration off for this location, never the rest of the plugin.
      try {
        refreshProjectConfig()
        await ctx.skill?.transform?.((editor: any) => {
          for (const skill of projectLoaded.skills) {
            try {
              editor.add({ id: skill.id, name: skill.name, description: skill.description, path: skill.path, content: skill.content })
            } catch {}
          }
        })
        await ctx.agent?.transform?.((editor: any) => {
          for (const spec of projectLoaded.agents) {
            try {
              editor.update(spec.id, (agent: any) => {
                if (!agent.name || agent.name === agent.id) agent.name = spec.id
                agent.system = spec.system
                if (spec.description !== undefined) agent.description = spec.description
                if (spec.mode !== undefined) agent.mode = spec.mode
                if (spec.hidden !== undefined) agent.hidden = spec.hidden
                if (spec.color !== undefined) agent.color = spec.color
                if (spec.steps !== undefined) agent.steps = spec.steps
                if (spec.model !== undefined) agent.model = spec.model
              })
            } catch {}
          }
        })
        await ctx.command?.transform?.((editor: any) => {
          for (const spec of projectLoaded.commands) {
            try {
              editor.add({
                name: spec.name,
                description: spec.description,
                execute: async (invocation: any) => {
                  if (!stillTrusted()) throw new Error(`/${spec.name} comes from a repository BelloCode no longer trusts.`)
                  const prompt = invocation?.prompt ?? {}
                  await ctx.session.prompt({
                    sessionID: invocation.sessionID,
                    text: P.expandTemplate(spec.template, String(prompt.text ?? "")),
                    ...(prompt.files ? { files: prompt.files } : {}),
                    ...(prompt.agents ? { agents: prompt.agents } : {}),
                    ...(prompt.skills ? { skills: prompt.skills } : {}),
                    ...(invocation.delivery ? { delivery: invocation.delivery } : {}),
                  })
                },
              })
            } catch {}
          }
        })
      } catch {}
    }

    /** Writes (or removes) the session's repository AGENTS.md entry when the text changed. Bounded by a time limit so
     * a slow write never holds up a prompt. */
    const putProjectInstructions = async (sessionID: string, directory: string) => {
      if (projectConfig?.mode !== "bellocode") return
      let text: string
      try {
        text = P.instructionsText(P.instructionFiles(directory)) ?? ""
      } catch {
        return
      }
      if (projectInstructionsWritten.get(sessionID) === text) return
      const timer = new AbortController()
      let done = false
      try {
        const write = Promise.resolve(
          text
            ? ctx.session.instructions.entry.put({ sessionID, key: P.INSTRUCTIONS_KEY, value: text })
            : ctx.session.instructions.entry.remove({ sessionID, key: P.INSTRUCTIONS_KEY }),
        )
        done = await Promise.race([write.then(() => true, () => false), sleep(2_000, timer.signal).then(() => false)])
      } catch {
        done = false
      } finally {
        timer.abort()
      }
      if (!done) return
      projectInstructionsWritten.set(sessionID, text)
      if (projectInstructionsWritten.size > 4_000) projectInstructionsWritten.delete(projectInstructionsWritten.keys().next().value as string)
    }
    if (projectConfig?.mode === "bellocode" && ctx.session?.hook) {
      // Awaited by opencode before a prompt is admitted (SessionPrompt.prepare), so even the first turn has the text.
      await ctx.session.hook("prompt", async (event: any) => {
        const sessionID = event?.sessionID as string | undefined
        if (!sessionID) return
        // A failed lookup says nothing about the files: keep the entry as it is rather than removing it (N22).
        const session = await Promise.resolve()
          .then(() => ctx.session.get({ sessionID }))
          .then((value: any) => value?.data ?? value, () => undefined)
        const directory = session?.location?.directory
        if (typeof directory !== "string" || !directory) return
        await putProjectInstructions(sessionID, directory)
      })
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

    /** A session's children, every page (`complete` is false when the page limit ends the listing first). */
    const childPages = async (sessionID: string): Promise<{ sessions: Session[]; complete: boolean }> => {
      const out: Session[] = []
      const seen = new Set<string>()
      let cursor: unknown
      for (let page = 0; page < CHILD_PAGES; page++) {
        const value = await ctx.session.list({ parentID: sessionID, limit: PAGE_SIZE, ...(cursor ? { cursor } : {}) })
        const batch = list<Session>(value)
        const fresh = batch.filter((item) => !seen.has(item.id))
        for (const item of fresh) seen.add(item.id)
        out.push(...fresh)
        cursor = (value?.cursor ?? value?.data?.cursor)?.next
        // A short page, no cursor, or a page with nothing new (a cursor the API ignored) ends the listing.
        if (batch.length < PAGE_SIZE || !cursor || fresh.length === 0) return { sessions: out, complete: true }
      }
      return { sessions: out, complete: false }
    }

    const children = async (sessionID: string): Promise<Session[]> => (await childPages(sessionID)).sessions

    /** Every descendant, parents before children. `unexamined` counts listed sessions whose children were not read
     *  (the traversal limit, or a list that failed), so a caller never mistakes a partial walk for the whole tree. */
    const walk = async (sessionID: string): Promise<{ sessions: Session[]; complete: boolean; unexamined: number }> => {
      const out: Session[] = []
      const queue = [sessionID]
      let complete = true
      let unexamined = 0
      while (queue.length) {
        if (out.length >= TREE_LIMIT) {
          unexamined += queue.length
          complete = false
          break
        }
        const parent = queue.shift() as string
        let next: { sessions: Session[]; complete: boolean }
        try {
          next = await childPages(parent)
        } catch {
          unexamined += 1
          complete = false
          continue
        }
        if (!next.complete) complete = false
        out.push(...next.sessions)
        queue.push(...next.sessions.map((child) => child.id))
      }
      return { sessions: out, complete, unexamined }
    }

    const descendants = async (sessionID: string): Promise<Session[]> => (await walk(sessionID)).sessions

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

    /** Interrupts `sessionID`'s running descendants (deepest first) and then the session, then reads each back until
     *  it is no longer running (or `CONFIRM_MS` passes). Reports requested, acknowledged, failed, settled, still running
     *  and unexamined separately: a count never includes a task that is still running. */
    const cascadeStop = async (
      sessionID: string,
      includeSelf: boolean,
      signal?: AbortSignal,
      confirm = true,
    ): Promise<L.StopReport> => {
      const tree = await walk(sessionID)
      const below = tree.sessions.filter(L.isRunning)
      const until = Date.now() + CASCADE_WINDOW_MS
      if (below.length) cascading.set(sessionID, until)
      const targets = below.reverse().map((child) => child.id)
      if (includeSelf) targets.push(sessionID)
      const acknowledged: string[] = []
      const failed: Array<{ id: string; error: string }> = []
      for (const id of targets) {
        if (id !== sessionID) cascading.set(id, until)
        try {
          await ctx.session.interrupt({ sessionID: id })
          acknowledged.push(id)
        } catch (error) {
          failed.push({ id, error: L.oneLine(String((error as any)?.message ?? error), 160) })
        }
      }
      const settled: string[] = []
      let pending = confirm ? [...acknowledged] : []
      const deadline = Date.now() + CONFIRM_MS
      while (pending.length) {
        const still: string[] = []
        for (const id of pending) {
          const session = await get(id).catch(() => undefined)
          if (session && !L.isRunning(session)) settled.push(id)
          else still.push(id)
        }
        pending = still
        if (!pending.length || Date.now() >= deadline || signal?.aborted) break
        await sleep(Math.min(CONFIRM_POLL_MS, Math.max(10, deadline - Date.now())), signal)
      }
      return {
        requested: targets,
        acknowledged,
        failed,
        settled,
        stillRunning: confirm ? pending : acknowledged,
        unexamined: tree.unexamined,
        complete: tree.complete,
      }
    }

    const summaryOf = async (sessionID: string) => L.clip(L.lastReply(await messages(sessionID)), 2_000)

    /** Waits until the thread (and optionally its descendants) stops running, the deadline passes or the call stops. */
    const waitIdle = async (sessionID: string, seconds: number, includeChildren: boolean, signal: AbortSignal) => {
      const deadline = Date.now() + seconds * 1000
      while (!signal.aborted) {
        const session = await get(sessionID)
        let busy = L.isRunning(session)
        let complete = true
        if (!busy && includeChildren) {
          // A tree that could not be fully listed cannot be confirmed idle.
          const tree = await walk(sessionID)
          busy = tree.sessions.some(L.isRunning)
          complete = tree.complete
        }
        if (!busy && complete) return { settled: true, session }
        if (Date.now() >= deadline) return { settled: false, session, ...(complete ? {} : { incomplete: true }) }
        await sleep(Math.min(750, Math.max(50, deadline - Date.now())), signal)
      }
      return { settled: false, session: await get(sessionID) } as { settled: boolean; session: Session; incomplete?: boolean }
    }

    const putGuidance = async (session: Session) => {
      guided.add(session.id)
      if (guided.size > 4_000) guided.delete(guided.values().next().value as string)
      const depth = L.depthOf([session, ...(await ancestors(session))])
      const value = L.guidance({ depth, limits, delegated: Boolean(session.parentID) })
      await ctx.session.instructions.entry.put({ sessionID: session.id, key: GUIDANCE_KEY, value }).catch(() => undefined)
      await putProjectInstructions(session.id, session.location?.directory).catch(() => undefined)
      if (container) {
        // Where commands run: rewritten at each run so it reflects the image and any blocked state.
        const text = C.containerGuidance(readExecConfig(), session.location?.directory)
        await ctx.session.instructions.entry
          .put({ sessionID: session.id, key: C.CONTAINER_GUIDANCE_KEY, value: text })
          .catch(() => undefined)
      }
    }

    // MARK: Auto mode and risk instrumentation (docs/features/auto-mode.md)
    // `permission.evaluate` runs after the rules and saved grants and before the request is created (verified on 2.3.0
    // and 2.3.2). In an Auto session every `allow` becomes `ask`, so a saved "always" grant cannot skip BelloCode's
    // policy (mandatory gates) and the app decides each request (it replies `once`, never `always`). Other modes are
    // only recorded: each call's evaluations are stamped onto its result for the app's risk notices.
    const callPermissions = new A.CallPermissions()
    const hooks = { evaluate: false, executeBefore: false, executeAfter: false }
    const modeOfSession = async (sessionID: string): Promise<A.Mode> => {
      try {
        return A.modeOf((await get(sessionID)).permissions as A.Rule[] | undefined)
      } catch {
        // Never "other": an unreadable session must not keep a saved allow (R11).
        return "unknown"
      }
    }
    if (ctx.permission?.hook) {
      await ctx.permission.hook("evaluate", async (event: any) => {
        const callID = event?.source?.id as string | undefined
        const effectIn = event.effect as A.Effect
        if (event.action === A.PROBE_ACTION) {
          // Contract probe: proves the hook is awaited (the create call returns only after this sleep).
          await sleep(Math.min(2_000, Math.max(0, Number(event.metadata?.delayMs ?? 300))))
          const wanted = event.metadata?.effect
          if (wanted === "allow" || wanted === "ask" || wanted === "deny") event.effect = wanted
          trace.add({ hook: "evaluate", sessionID: event.sessionID, action: event.action, effectIn, effectOut: event.effect })
          return
        }
        const mode = await modeOfSession(event.sessionID)
        const decided = A.autoEffect(mode, effectIn)
        if (decided.changed) {
          event.effect = decided.effect
          event.message = mode === "unknown" ? A.UNKNOWN_MODE_MESSAGE : A.AUTO_MESSAGE
        }
        callPermissions.record(callID, { action: String(event.action), resources: list<string>(event.resources), effect: event.effect })
        trace.add({
          hook: "evaluate", sessionID: event.sessionID, callID, action: event.action,
          resources: list<string>(event.resources).length, effectIn, effectOut: event.effect, mode,
        })
      })
      hooks.evaluate = true
    }
    if (ctx.tool?.hook) {
      await ctx.tool.hook("execute.before", (event: any) => {
        trace.add({ hook: "execute.before", sessionID: event.sessionID, callID: event.id, tool: event.tool })
      })
      await ctx.tool.hook("execute.after", (event: any) => {
        const evaluated = callPermissions.take(event.id)
        trace.add({ hook: "execute.after", sessionID: event.sessionID, callID: event.id, tool: event.tool, status: event.status })
        if (evaluated?.length && event.status === "completed" && event.result && typeof event.result === "object") {
          event.result.metadata = { ...(event.result.metadata ?? {}), [A.PERMISSIONS_METADATA_KEY]: evaluated }
        }
      })
      hooks.executeBefore = true
      hooks.executeAfter = true
    }

    // Agent-initiated interrupts: rate limits, cascade cap, de-duplication (in this server process).
    const interruptGuard = new A.InterruptGuard()
    const interrupting = new Map<string, Promise<any>>()

    const writeInterrupt = async (sessionID: string, record: A.InterruptRecord | null) => {
      const fresh = await get(sessionID)
      const metadata = { ...(fresh.metadata ?? {}) } as Record<string, unknown>
      if (record) metadata.bellocode_interrupt = record
      else delete metadata.bellocode_interrupt
      await ctx.session.update({ sessionID, metadata })
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
          // The call's model, else the agent's, else the owner's default for delegated threads (Settings ▸ Models;
          // read at each call, so a change applies without a restart).
          const modelDefaultsFile: string | undefined = typeof ctx.options?.modelDefaultsFile === "string" ? ctx.options.modelDefaultsFile : undefined
          const ownerDefault = modelDefaultsFile ? L.readModelDefaults(() => readFileSync(modelDefaultsFile, "utf8")) : undefined
          let catalog: any[] | undefined
          if (!parsed && !agent.model && ownerDefault && ownerDefault !== "thread" && ownerDefault !== "server") {
            catalog = await Promise.resolve()
              .then(() => ctx.model.list({}))
              .then((value: any) => list<any>(value), () => undefined)
          }
          const model = parsed ?? agent.model ?? L.childModel(ownerDefault, caller.model, (item) => L.modelUsable(catalog, item)) ?? undefined
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
          // S2: a child inherits the caller's session rules on the server; prompt only once that is confirmed.
          if (!L.rulesConfirmed(caller.permissions, (await get(child.id)).permissions))
            fail(`Created child ${child.id}, but the server did not confirm this thread's permission rules for it, so the task was not started.${L.recoveryNote(made)}`)
          // C1: the child is prompted only once it is confirmed in its worktree (never silently in this checkout).
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
          const report = await cascadeStop(target.id, true, tool.signal)
          return { content: L.describeStop(target.id, report, true), metadata: { stop: report } }
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
          // Checked before anything is created: a typo or a sub-agent (which would run a top-level thread with a
          // sub-agent's prompt and step limit) is refused, as delegate_task refuses a primary agent.
          const agents = specs.some((spec: any) => spec.agent) ? list<any>(await ctx.agent.list({})) : []
          for (const spec of specs) {
            const parsed = L.parseModel(spec.model)
            if (parsed && "error" in parsed) fail(parsed.error)
            const agentID = typeof spec.agent === "string" ? spec.agent.trim() : ""
            if (!agentID) continue
            const agent = agents.find((item) => item.id === agentID)
            if (!agent) fail(`Unknown agent "${agentID}". Call orchestrator_capabilities for the list.`)
            if (agent.mode === "subagent") fail(`Agent "${agentID}" is a sub-agent; a new thread needs a primary agent (build or plan). Use delegate_task for sub-agents.`)
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
              ...(typeof spec.agent === "string" && spec.agent.trim() ? { agent: spec.agent.trim() } : {}),
              ...(parsed ? { model: parsed } : {}),
              ...(directory ? { location: { directory } } : {}),
              // S2: top-level threads do not inherit rules; they get the caller's, confirmed before any prompt.
              ...(caller.permissions?.length ? { permissions: caller.permissions } : {}),
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
            if (spec.prompt && !L.rulesConfirmed(caller.permissions, (await get(session.id)).permissions))
              fail(`Created thread ${session.id}, but the server did not confirm this thread's permission rules for it, so its first prompt was not sent.${L.recoveryNote(made)}`)
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
          // A thread another agent stopped stays stopped until the user resumes it: steering is turned into queueing,
          // and the message is admitted without waking it (a queued prompt to an idle thread would start a run, and
          // that run would clear the hold).
          const held = Boolean((target.metadata as any)?.bellocode_interrupt?.held)
          const delivery = input.delivery === "steer" && !held ? "steer" : "queue"
          await ctx.session.prompt({
            sessionID: target.id,
            text: `[Message from ${from}]\n${String(input.message)}`,
            delivery,
            ...(held ? { resume: false } : {}),
          })
          return {
            content: `Sent to ${target.id} (${delivery}).${held ? " That thread was stopped by an interrupt; your message waits until the user resumes it." : ""}`,
            metadata: { threadID: target.id },
          }
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
          const output = describe(waited.session, {
            settled: waited.settled,
            state,
            summary,
            ...(waited.incomplete ? { note: "The task tree was too large to list completely, so it could not be confirmed idle." } : {}),
          })
          return { content: JSON.stringify(output, null, 1) }
        },
      },
      {
        name: "thread_interrupt",
        description: [
          "Stop another thread's current run and its child tasks, with a reason. In this project it runs without asking:",
          "it is attributed to you and shown in both threads, and the stopped thread's queued work is held until the user resumes it.",
          "A thread in another project needs the user's approval. Rate-limited; use it only when that thread is doing harmful or conflicting work.",
        ].join(" "),
        input: obj(
          { threadID: str("Thread to stop."), reason: str("Why, in one sentence. Shown to the user in both threads.") },
          ["threadID", "reason"],
        ),
        execute: async (input: any, tool: ToolContext) => {
          const reason = A.cleanReason(input.reason)
          if (!reason) fail("Give a reason: the user sees who stopped the thread and why.")
          if (!tool.sessionID) fail("Unattributed interrupt refused: no calling thread.")
          const { caller, target, scope } = await reach(tool, String(input.threadID), "thread_interrupt")
          if (scope === "self") fail("Use your own final message to stop; you cannot interrupt yourself.")
          if ((target.time as any)?.archived) fail(`Thread ${target.id} is archived, so it was not interrupted.`)
          const running = L.isRunning(target) || (await descendants(target.id)).some(L.isRunning)
          if (!running) {
            return {
              content: `${target.id} is not running, so nothing was stopped.`,
              metadata: { threadID: target.id, interrupt: { requested: "stop", actual: "not_running" } },
            }
          }
          const inflight = interrupting.get(target.id)
          if (inflight) {
            const earlier = await inflight.catch(() => undefined)
            return {
              content: `${target.id} was already being stopped by another request; not repeated.${earlier?.content ? `\n${earlier.content}` : ""}`,
              metadata: { threadID: target.id, deduplicated: true },
            }
          }
          if (scope !== "descendant") {
            const refusal = interruptGuard.check(caller.id, target.id)
            if (refusal) fail(refusal)
            interruptGuard.record(caller.id, target.id)
          }
          const work = (async () => {
            const report = await cascadeStop(target.id, true, tool.signal)
            const actual: A.InterruptRecord["actual"] = report.failed.some((item) => item.id === target.id)
              ? "failed"
              : report.stillRunning.includes(target.id)
                ? "still_running"
                : "stopped"
            const record: A.InterruptRecord = {
              by: caller.id,
              byTitle: caller.title ?? undefined,
              reason,
              at: Date.now(),
              requested: "stop",
              actual,
              held: true,
            }
            await writeInterrupt(target.id, record).catch(() => undefined)
            // A note in the stopped thread (no run is started), so its transcript and model context say who and why.
            await ctx.session
              .synthetic({ sessionID: target.id, text: A.interruptNote(record), resume: false })
              .catch(() => undefined)
            return {
              content: `${L.describeStop(target.id, report, true)}\nRequested: stop. Actual: ${actual}. Attributed to this thread; the user sees it in both threads, and ${target.id}'s queued work is held until they resume it.`,
              metadata: { stop: report, interrupt: record, threadID: target.id, title: target.title ?? null },
            }
          })()
          interrupting.set(target.id, work)
          try {
            return await work
          } finally {
            interrupting.delete(target.id)
          }
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
          trace: { input: { type: "object" }, output: { type: "object" } },
          projectConfig: { input: { type: "object" }, output: { type: "object" } },
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
          auto: { hooks, evaluations: trace.count },
          appTools: list<any>(await ctx.tool.list())
            .filter(L.isAppTool)
            .map((tool) => ({ id: tool.id ?? tool.name, codemode: tool.options?.codemode !== false })),
        }),
        // Re-reads the trust file and this location's repository files, then replays the transforms. Names only;
        // `{ reload: false }` only reports what is loaded.
        projectConfig: async (input: any) => {
          if (input?.reload === false) {
            return {
              mode: projectConfig?.mode ?? "off",
              trusted: projectLoaded.trusted,
              agents: projectLoaded.agents.map((agent) => agent.id),
              commands: projectLoaded.commands.map((command) => command.name),
              skills: projectLoaded.skills.map((skill) => skill.id),
              skipped: projectLoaded.skipped,
            }
          }
          // The app requires `applied` and the trust revision it wrote before it reports a trust change as done (A10).
          const failures: string[] = []
          if (!refreshProjectConfig()) failures.push("repository")
          if (projectConfig?.mode === "bellocode") {
            const kinds = ["skills", "agents", "commands"]
            const results = await Promise.allSettled([
              Promise.resolve().then(() => ctx.skill?.reload?.()),
              Promise.resolve().then(() => ctx.agent?.reload?.()),
              Promise.resolve().then(() => ctx.command?.reload?.()),
            ])
            results.forEach((result, index) => {
              if (result.status === "rejected") failures.push(kinds[index])
            })
          }
          return {
            mode: projectConfig?.mode ?? "off",
            revision: trustRevision,
            applied: failures.length === 0,
            failures,
            trusted: projectLoaded.trusted,
            agents: projectLoaded.agents.map((agent) => agent.id),
            commands: projectLoaded.commands.map((command) => command.name),
            skills: projectLoaded.skills.map((skill) => skill.id),
            skipped: projectLoaded.skipped,
          }
        },
        // Hook order and coverage for the contract tests and diagnostics: names, effects and counts, never content.
        trace: async (input: any) => {
          try {
            const entries = trace.list(typeof input?.sessionID === "string" ? input.sessionID : undefined)
            if (input?.clear === true) trace.clear()
            return { entries: JSON.parse(JSON.stringify(entries)), count: trace.count, hooks: { ...hooks } }
          } catch (error) {
            return { entries: [], count: -1, error: String((error as any)?.message ?? error) }
          }
        },
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
      // Read the metadata again just before writing and change only the `bellocode` key, so keys other writers set
      // meanwhile (BelloCode's merge-request links) are not replaced with the copy read before the transcript.
      const fresh = await get(sessionID)
      const metadata = { ...(fresh.metadata ?? {}) }
      metadata.bellocode = { ...L.belloMeta(fresh), summary, outcome, settledAt: Date.now() }
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
          // A run started (the user resumed or sent): the interrupt hold is over.
          const started = await get(sessionID).catch(() => undefined)
          const record = (started?.metadata as any)?.bellocode_interrupt as A.InterruptRecord | undefined
          const cut = cascading.get(sessionID)
          if (record?.held && !(cut && cut > Date.now())) await writeInterrupt(sessionID, { ...record, held: false }).catch(() => undefined)
          // Sessions created before the plugin (or while it reloaded) get their guidance at their next run; with
          // containers, every run refreshes it (image, tools, blocked state).
          if (!guided.has(sessionID) || container) await putGuidance(await get(sessionID)).catch(() => undefined)
          else if (started) await putProjectInstructions(sessionID, started.location?.directory).catch(() => undefined)
          // A child's cancelled report wakes its parent; inside a cascade window that restart is cut at once.
          const until = cascading.get(sessionID)
          if (until && until > Date.now()) await ctx.session.interrupt({ sessionID }).catch(() => undefined)
          else if (until) cascading.delete(sessionID)
          return
        }
        case "session.execution.interrupted":
          if (event.data.reason === "user") await cascadeStop(sessionID, false, undefined, false)
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
