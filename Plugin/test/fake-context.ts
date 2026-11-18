// A scripted stand-in for opencode's plugin context (the promise API server.ts uses), for failure-path tests of the
// orchestration tools. Sessions live in memory; each operation can be overridden per test.

import plugin from "../server.ts"

export type FakeSession = {
  id: string
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
  }
  const tools: any[] = []
  let counter = 0
  let worktreeCounter = 0
  let release: (() => void) | undefined
  const ctx = {
    options,
    location: { directory: "/repo" },
    session: {
      get: async ({ sessionID }: any) => {
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
      update: async () => undefined,
      context: async () => ({ data: [] }),
      instructions: { entry: { put: async () => undefined } },
    },
    worktree: {
      create: async (input: any) => {
        calls.worktrees.push(input)
        if (overrides.worktreeCreate) return overrides.worktreeCreate(input)
        worktreeCounter += 1
        return { data: { directory: `/worktrees/wt${worktreeCounter}` } }
      },
    },
    agent: { list: async () => ({ data: [{ id: "general", mode: "subagent" }] }) },
    model: { list: async () => ({ data: [] }) },
    permission: { assert: async () => undefined, list: async () => ({ data: [] }), reply: async () => undefined },
    tool: {
      transform: async (callback: any) => callback({ add: (tool: any) => tools.push(tool), list: () => [] }),
      list: async () => [],
    },
    rpc: { register: async () => ({ dispose: async () => undefined }) },
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
  return { sessions, calls, add, run, dispose }
}

export const running = { created: 1, busy: 10, idle: 5 }
export const idle = { created: 1, busy: 10, idle: 20 }
