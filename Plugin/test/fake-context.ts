// A scripted stand-in for opencode's plugin context (the promise API server.ts uses), for failure-path tests of the
// orchestration tools. Sessions live in memory; each operation can be overridden per test.

import plugin from "../server.ts"

export type FakeSession = {
  id: string
  permissions?: Array<{ action: string; resource: string; effect: string }>
  parentID?: string
  projectID?: string
  title?: string
  location?: { directory?: string }
  metadata?: Record<string, unknown>
  time: { created: number; busy?: number; idle?: number }
}

export type Overrides = {
  worktreeCreate?: (input: any) => Promise<any>
  sessionMove?: (input: any, sessions: Map<string, FakeSession>) => Promise<any>
  sessionCreate?: (input: any, made: FakeSession) => FakeSession
  sessionInterrupt?: (input: any, sessions: Map<string, FakeSession>) => Promise<any>
  sessionList?: (input: any, sessions: Map<string, FakeSession>) => Promise<any>
  /** The location directory the plugin is set up for (default "/repo"). */
  location?: string
  sessionGet?: (input: any, sessions: Map<string, FakeSession>) => Promise<any>
  /** Transform reloads that reject ("skill", "agent", "command"). */
  failingReloads?: string[]
}

export async function makePlugin(overrides: Overrides = {}, options: Record<string, unknown> = {}) {
  const sessions = new Map<string, FakeSession>()
  const calls = {
    prompts: [] as any[],
    moves: [] as any[],
    interrupts: [] as any[],
    worktrees: [] as any[],
    creates: [] as any[],
    lists: [] as any[],
    synthetic: [] as any[],
    updates: [] as any[],
    instructions: [] as Array<{ op: "put" | "remove"; sessionID: string; value?: string }>,
    transforms: { skill: [] as any[], agent: [] as any[], command: [] as any[] },
  }
  const rpcHandlers: Record<string, (input: any) => Promise<any>> = {}
  const transform = (kind: "skill" | "agent" | "command") => ({
    transform: async (callback: any) => {
      const editor = {
        add: (item: any) => calls.transforms[kind].push(item),
        update: (id: string, edit: any) => {
          const agent: any = { id }
          edit(agent)
          calls.transforms[kind].push(agent)
        },
      }
      callback(editor)
    },
    reload: async () => {
      if (overrides.failingReloads?.includes(kind)) throw new Error(`${kind} reload failed`)
    },
  })
  const hooks: Record<string, Array<(event: any) => any>> = {}
  const addHook = (name: string) => async (hook: string, fn: (event: any) => any) => {
    ;(hooks[`${name}.${hook}`] ??= []).push(fn)
  }
  const tools: any[] = []
  let counter = 0
  let worktreeCounter = 0
  let release: (() => void) | undefined
  const ctx = {
    options,
    location: { directory: overrides.location ?? "/repo" },
    skill: transform("skill"),
    agent: { ...transform("agent"), list: async () => ({ data: [{ id: "general", mode: "subagent" }] }) },
    command: transform("command"),
    session: {
      hook: addHook("session"),
      get: async ({ sessionID }: any) => {
        if (overrides.sessionGet) return overrides.sessionGet({ sessionID }, sessions)
        const found = sessions.get(sessionID)
        if (!found) throw new Error("not found")
        return { data: structuredClone(found) }
      },
      list: async (input: any) => {
        calls.lists.push(input)
        if (overrides.sessionList) return overrides.sessionList(input, sessions)
        const all = [...sessions.values()].filter((item) => input.parentID === undefined || item.parentID === input.parentID)
        return { data: all.slice(0, input.limit ?? all.length).map((item) => structuredClone(item)) }
      },
      create: async (input: any) => {
        calls.creates.push(input)
        counter += 1
        const parent = input.parentID ? sessions.get(input.parentID) : undefined
        let made: FakeSession = {
          id: `ses_${String(counter).padStart(3, "0")}`,
          parentID: input.parentID,
          projectID: "p1",
          title: input.title,
          location: input.location ?? { directory: parent?.location?.directory ?? "/repo" },
          metadata: input.metadata,
          time: { created: counter },
        }
        if (overrides.sessionCreate) made = overrides.sessionCreate(input, made)
        sessions.set(made.id, made)
        return { data: structuredClone(made) }
      },
      move: async (input: any) => {
        calls.moves.push(input)
        if (overrides.sessionMove) return overrides.sessionMove(input, sessions)
        const found = sessions.get(input.sessionID)
        if (found) found.location = { directory: input.directory }
      },
      prompt: async (input: any) => {
        calls.prompts.push(input)
      },
      interrupt: async (input: any) => {
        calls.interrupts.push(input)
        if (overrides.sessionInterrupt) return overrides.sessionInterrupt(input, sessions)
        const found = sessions.get(input.sessionID)
        if (found) found.time = { ...found.time, idle: (found.time.busy ?? 0) + 1 }
      },
      update: async (input: any) => {
        calls.updates.push(input)
        const found = sessions.get(input.sessionID)
        if (found && input.metadata) found.metadata = structuredClone(input.metadata)
      },
      synthetic: async (input: any) => {
        calls.synthetic.push(input)
      },
      context: async () => ({ data: [] }),
      instructions: {
        entry: {
          put: async (input: any) => {
            calls.instructions.push({ op: "put", sessionID: input.sessionID, value: input.value })
          },
          remove: async (input: any) => {
            calls.instructions.push({ op: "remove", sessionID: input.sessionID })
          },
        },
      },
    },
    worktree: {
      create: async (input: any) => {
        calls.worktrees.push(input)
        if (overrides.worktreeCreate) return overrides.worktreeCreate(input)
        worktreeCounter += 1
        return { data: { directory: `/worktrees/wt${worktreeCounter}` } }
      },
    },
    model: { list: async () => ({ data: [] }) },
    permission: {
      assert: async (input: any) => {
        ;(calls as any).asserts = [...((calls as any).asserts ?? []), input]
      },
      list: async () => ({ data: [] }),
      reply: async () => undefined,
      hook: addHook("permission"),
    },
    shell: { hook: addHook("shell") },
    tool: {
      hook: addHook("tool"),
      transform: async (callback: any) => callback({ add: (tool: any) => tools.push(tool), list: () => [] }),
      list: async () => [],
    },
    rpc: {
      register: async (_spec: any, handlers: Record<string, (input: any) => Promise<any>>) => {
        Object.assign(rpcHandlers, handlers)
        return { dispose: async () => undefined }
      },
    },
    event: {
      subscribe: () => ({
        [Symbol.asyncIterator]: () => ({
          next: () => new Promise<IteratorResult<any>>((resolve) => (release = () => resolve({ done: true, value: undefined }))),
          return: async () => {
            release?.()
            return { done: true, value: undefined }
          },
        }),
      }),
    },
  }
  const dispose = await plugin.setup(ctx)

  const add = (session: Partial<FakeSession> & { id: string }) => {
    const value: FakeSession = { projectID: "p1", location: { directory: "/repo" }, time: { created: 1 }, ...session }
    sessions.set(value.id, value)
    return value
  }
  const run = async (name: string, input: any, caller = "ses_caller") => {
    const tool = tools.find((item) => item.name === name)
    if (!tool) throw new Error(`no tool ${name}`)
    return tool.execute(input, {
      sessionID: caller,
      agent: "build",
      messageID: "msg_1",
      id: "call_1",
      signal: new AbortController().signal,
      progress: async () => undefined,
    })
  }
  /** Runs every hook registered under `name` (e.g. "permission.evaluate") on `event`, as opencode does. */
  const fire = async (name: string, event: any) => {
    for (const fn of hooks[name] ?? []) await fn(event)
    return event
  }
  const rpc = (method: string, input: any = {}) => rpcHandlers[method](input)
  return { sessions, calls, add, run, dispose, fire, hooks, rpc }
}

export const running = { created: 1, busy: 10, idle: 5 }
export const idle = { created: 1, busy: 10, idle: 20 }
