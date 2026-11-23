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

// N15: the owner's delegated-thread model is used only while the catalog offers it.
describe("delegate_task and the owner's default model", () => {
  const { mkdtempSync, writeFileSync, rmSync } = require("fs")
  const { tmpdir } = require("os")
  const { join } = require("path")
  const defaults = (token: string) => {
    const dir = mkdtempSync(join(tmpdir(), "bc-models-"))
    const file = join(dir, "bellocode-models.json")
    writeFileSync(file, JSON.stringify({ version: 1, delegated: token }))
    return { file, cleanup: () => rmSync(dir, { recursive: true, force: true }) }
  }
  const input = { task: "Summarise the changes", description: "Summary" }

  test("an unavailable chosen model falls through to the parent's model", async () => {
    const file = defaults("gone/model")
    const plugin = await makePlugin({ models: [{ providerID: "openai", id: "gpt-x", enabled: true }] }, { modelDefaultsFile: file.file })
    plugin.add({ id: "ses_caller", ...({ model: { providerID: "anthropic", id: "claude-sonnet-5" } } as any) })
    await plugin.run("delegate_task", input)
    expect(plugin.calls.creates[0].model).toEqual({ providerID: "anthropic", id: "claude-sonnet-5" })
    await plugin.dispose()
    file.cleanup()
  })

  test("a disabled chosen model falls through; an enabled one is used", async () => {
    const file = defaults("openai/gpt-x")
    const disabled = await makePlugin({ models: [{ providerID: "openai", id: "gpt-x", enabled: false }] }, { modelDefaultsFile: file.file })
    disabled.add({ id: "ses_caller" })
    await disabled.run("delegate_task", input)
    expect(disabled.calls.creates[0].model).toBeUndefined()
    await disabled.dispose()
    const enabled = await makePlugin({ models: [{ providerID: "openai", id: "gpt-x", enabled: true }] }, { modelDefaultsFile: file.file })
    enabled.add({ id: "ses_caller" })
    await enabled.run("delegate_task", input)
    expect(enabled.calls.creates[0].model).toEqual({ providerID: "openai", id: "gpt-x" })
    await enabled.dispose()
    file.cleanup()
  })
})

describe("create_threads agent", () => {
  // GF14: the agent is checked like delegate_task's, before any thread or worktree exists.
  test("an unknown agent is refused before anything is created", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("create_threads", { threads: [{ title: "One" }, { title: "Two", agent: "biuld" }] }).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain('Unknown agent "biuld"')
    expect(plugin.calls.creates).toEqual([])
    await plugin.dispose()
  })

  test("a sub-agent cannot run a top-level thread", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    const error = await plugin.run("create_threads", { threads: [{ title: "One", agent: "general" }] }).then(
      () => undefined,
      (failure: Error) => failure,
    )
    expect(error?.message).toContain("is a sub-agent")
    expect(plugin.calls.creates).toEqual([])
    await plugin.dispose()
  })

  test("a primary agent is passed through", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    await plugin.run("create_threads", { threads: [{ title: "One", agent: " plan " }] })
    expect(plugin.calls.creates[0].agent).toBe("plan")
    await plugin.dispose()
  })
})
