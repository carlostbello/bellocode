import { describe, expect, test } from "bun:test"
import { makePlugin } from "./fake-context.ts"

// Deep review 1, C1: a "worktree" child must never run in the original checkout.
describe("delegate_task into a worktree", () => {
  const input = { task: "Refactor the parser", description: "Parser refactor", workspace: "worktree" }

  test("is prompted only after it is confirmed in the new worktree", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    const result = await plugin.run("delegate_task", input)
    expect(plugin.calls.moves).toEqual([{ sessionID: "ses_001", directory: "/worktrees/wt1" }])
    expect(plugin.sessions.get("ses_001")?.location?.directory).toBe("/worktrees/wt1")
    expect(plugin.calls.prompts.map((item) => item.sessionID)).toEqual(["ses_001"])
    expect(result.content).toContain("worktree /worktrees/wt1")
    await plugin.dispose()
  })

  test("a failed move fails the call, names what was created and prompts nothing", async () => {
    const plugin = await makePlugin({ sessionMove: async () => Promise.reject(new Error("busy")) })
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("delegate_task", input).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("Could not move ses_001 into worktree /worktrees/wt1")
    expect(error?.message).toContain("ses_001")
    expect(error?.message).toContain("worktree(s) /worktrees/wt1")
    expect(plugin.calls.prompts).toEqual([])
    await plugin.dispose()
  })

  test("a move that does not take effect fails the call before any prompt", async () => {
    const plugin = await makePlugin({ sessionMove: async () => undefined })
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("delegate_task", input).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("is not running in worktree /worktrees/wt1")
    expect(plugin.calls.prompts).toEqual([])
    await plugin.dispose()
  })

  test("a worktree without a usable directory starts nothing", async () => {
    for (const reply of [{ data: {} }, { data: { directory: "relative/path" } }, undefined]) {
      const plugin = await makePlugin({ worktreeCreate: async () => reply })
      plugin.add({ id: "ses_caller" })
      const error = await plugin.run("delegate_task", input).then(
        () => undefined,
        (failure: Error) => failure,
      )
      expect(error?.message).toContain("no usable worktree directory")
      expect(plugin.calls.creates).toEqual([])
      expect(plugin.calls.prompts).toEqual([])
      await plugin.dispose()
    }
  })

  test("shared delegation is unchanged (no worktree, no move)", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    await plugin.run("delegate_task", { ...input, workspace: "shared" })
    expect(plugin.calls.worktrees).toEqual([])
    expect(plugin.calls.moves).toEqual([])
    expect(plugin.calls.prompts.length).toBe(1)
    await plugin.dispose()
  })
})

describe("create_threads into worktrees", () => {
  const threads = [
    { title: "One", prompt: "first" },
    { title: "Two", prompt: "second" },
  ]

  test("each thread starts in its own confirmed worktree", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    await plugin.run("create_threads", { threads, workspace: "worktree" })
    expect(plugin.sessions.get("ses_001")?.location?.directory).toBe("/worktrees/wt1")
    expect(plugin.sessions.get("ses_002")?.location?.directory).toBe("/worktrees/wt2")
    expect(plugin.calls.prompts.map((item) => item.sessionID)).toEqual(["ses_001", "ses_002"])
    await plugin.dispose()
  })

  test("a missing worktree directory fails instead of falling back, naming earlier threads and worktrees", async () => {
    let made = 0
    const plugin = await makePlugin({
      worktreeCreate: async () => (++made === 1 ? { data: { directory: "/worktrees/a" } } : { data: {} }),
    })
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("create_threads", { threads, workspace: "worktree" }).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("no usable worktree directory")
    expect(error?.message).toContain("thread(s) ses_001")
    expect(error?.message).toContain("worktree(s) /worktrees/a")
    expect(plugin.calls.creates.length).toBe(1)
    expect(plugin.calls.prompts.map((item) => item.sessionID)).toEqual(["ses_001"])
    await plugin.dispose()
  })

  test("a thread created outside its worktree is moved, or the call fails before prompting it", async () => {
    const plugin = await makePlugin({
      sessionCreate: (_input, made) => ({ ...made, location: { directory: "/repo" } }),
      sessionMove: async () => Promise.reject(new Error("refused")),
    })
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("create_threads", { threads, workspace: "worktree" }).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("Could not move ses_001")
    expect(plugin.calls.prompts).toEqual([])
    await plugin.dispose()
  })

  test("a caller without a project cannot ask for worktrees", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller", projectID: undefined })
    const error = await plugin.run("create_threads", { threads, workspace: "worktree" }).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("cannot create worktrees")
    expect(plugin.calls.creates).toEqual([])
    await plugin.dispose()
  })
})
