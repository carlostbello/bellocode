import { describe, expect, test } from "bun:test"
import * as A from "../src/auto.ts"
import { idle, makePlugin, running } from "./fake-context.ts"

const AUTO = [
  { action: A.AUTO_MARKER_ACTION, resource: "*", effect: "ask" },
  { action: "*", resource: "*", effect: "ask" },
]
const FULL = [{ action: "*", resource: "*", effect: "allow" }]

describe("auto mode helpers", () => {
  test("mode comes from the session rules", () => {
    expect(A.modeOf(AUTO)).toBe("auto")
    expect(A.modeOf(FULL)).toBe("full")
    expect(A.modeOf([{ action: "edit", resource: "*", effect: "ask" }])).toBe("other")
    expect(A.modeOf(undefined)).toBe("other")
  })

  test("only Auto turns allow into ask; deny and ask are untouched", () => {
    expect(A.autoEffect("auto", "allow")).toEqual({ effect: "ask", changed: true })
    expect(A.autoEffect("auto", "ask").changed).toBe(false)
    expect(A.autoEffect("auto", "deny").effect).toBe("deny")
    expect(A.autoEffect("full", "allow").changed).toBe(false)
  })

  test("an unknown mode escalates an allow and preserves deny and ask (R11)", () => {
    expect(A.autoEffect("unknown", "allow")).toEqual({ effect: "ask", changed: true })
    expect(A.autoEffect("unknown", "deny")).toEqual({ effect: "deny", changed: false })
    expect(A.autoEffect("unknown", "ask")).toEqual({ effect: "ask", changed: false })
    expect(A.autoEffect("other", "allow").changed).toBe(false)
  })

  test("the trace is bounded and carries no resources", () => {
    const trace = new A.Trace(3)
    for (let i = 0; i < 5; i++) trace.add({ hook: "evaluate", action: "read", resources: 2 })
    expect(trace.list().length).toBe(3)
    expect(trace.count).toBe(5)
    expect(JSON.stringify(trace.list())).not.toContain("/")
  })

  test("call permissions are bounded per call and in total", () => {
    const map = new A.CallPermissions(2, 2)
    for (let i = 0; i < 4; i++) map.record("c1", { action: "read", resources: ["/a"], effect: "allow" })
    map.record("c2", { action: "read", resources: [], effect: "allow" })
    map.record("c3", { action: "read", resources: [], effect: "allow" })
    expect(map.take("c1")).toBeUndefined()
    expect(map.take("c3")?.length).toBe(1)
  })

  test("interrupt guard: per caller, per target, cascade cap", () => {
    let now = 1_000
    const guard = new A.InterruptGuard({ perCaller: 2, perTarget: 1, windowMs: 1_000, cascadeMs: 500 }, () => now)
    expect(guard.check("a", "t1")).toBeUndefined()
    guard.record("a", "t1")
    expect(guard.check("b", "t1")).toContain("that thread was already interrupted")
    guard.record("a", "t2")
    expect(guard.check("a", "t3")).toContain("this thread already interrupted")
    expect(guard.check("t1", "x")).toContain("cascade")
    now += 1_001
    expect(guard.check("a", "t3")).toBeUndefined()
    expect(guard.check("t1", "x")).toBeUndefined()
  })

  test("interrupt guard maps are bounded: checks add nothing, expired entries go, the oldest past the cap (N26)", () => {
    let now = 1_000
    const guard = new A.InterruptGuard({ perCaller: 2, perTarget: 2, windowMs: 1_000, cascadeMs: 500, maxThreads: 3 }, () => now)
    // Checks alone never store anything.
    for (let i = 0; i < 100; i++) expect(guard.check(`caller${i}`, `target${i}`)).toBeUndefined()
    expect(guard.sizes).toEqual({ callers: 0, targets: 0, interrupted: 0 })

    // Many distinct threads: each map stays at the cap, and the most recent ones are kept (still limited).
    for (let i = 0; i < 50; i++) guard.record(`c${i}`, `t${i}`)
    expect(guard.sizes).toEqual({ callers: 3, targets: 3, interrupted: 3 })
    guard.record("c49", "t48")
    expect(guard.check("c49", "x")).toContain("this thread already interrupted")
    expect(guard.check("y", "t48")).toContain("that thread was already interrupted")
    expect(guard.check("t49", "x")).toContain("cascade")

    // Expired entries are dropped when they are read and before anything recent is evicted.
    now += 1_001
    expect(guard.check("c49", "t48")).toBeUndefined()
    expect(guard.check("t49", "x")).toBeUndefined()
    expect(guard.sizes.callers).toBe(2)
    guard.record("fresh1", "f1")
    guard.record("fresh2", "f2")
    guard.record("fresh3", "f3")
    expect(guard.sizes).toEqual({ callers: 3, targets: 3, interrupted: 3 })
    guard.record("fresh1", "f1")
    expect(guard.check("fresh1", "z")).toContain("this thread already interrupted")
  })

  test("reasons are required, one line and bounded", () => {
    expect(A.cleanReason("  ")).toBeUndefined()
    expect(A.cleanReason(42)).toBeUndefined()
    expect(A.cleanReason("a\n b")).toBe("a b")
    expect(A.cleanReason("x".repeat(500))!.length).toBe(200)
  })
})

describe("hooks", () => {
  test("evaluate: a failed session lookup is unknown, so a saved-grant allow is escalated (R11)", async () => {
    const plugin = await makePlugin()
    // No such session: the lookup throws, as it does when the server cannot read it.
    const saved = await plugin.fire("permission.evaluate", {
      sessionID: "ses_unreadable", action: "shell", resources: ["git push"], effect: "allow", source: { id: "call_u" },
    })
    expect(saved.effect).toBe("ask")
    expect(saved.message).toBe(A.UNKNOWN_MODE_MESSAGE)
    const denied = await plugin.fire("permission.evaluate", {
      sessionID: "ses_unreadable", action: "shell", resources: ["rm -rf /"], effect: "deny", source: { id: "call_d" },
    })
    expect(denied.effect).toBe("deny")
    await plugin.dispose()
  })

  test("evaluate: Auto turns a saved-grant allow into ask; Full access is recorded and stamped on the result", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_auto", permissions: AUTO })
    plugin.add({ id: "ses_full", permissions: FULL })
    const auto = await plugin.fire("permission.evaluate", {
      sessionID: "ses_auto", action: "shell", resources: ["git status"], effect: "allow", source: { id: "call_a" },
    })
    expect(auto.effect).toBe("ask")
    expect(auto.message).toBe(A.AUTO_MESSAGE)
    const full = await plugin.fire("permission.evaluate", {
      sessionID: "ses_full", action: "read", resources: ["/repo/.env"], effect: "allow", source: { id: "call_f" },
    })
    expect(full.effect).toBe("allow")
    const after = await plugin.fire("tool.execute.after", {
      sessionID: "ses_full", id: "call_f", tool: "read", status: "completed", result: { content: "x", metadata: { a: 1 } },
    })
    expect(after.result.metadata.a).toBe(1)
    expect(after.result.metadata[A.PERMISSIONS_METADATA_KEY]).toEqual([{ action: "read", resources: ["/repo/.env"], effect: "allow" }])
    await plugin.dispose()
  })

  test("the contract probe waits before it decides", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_x" })
    const started = Date.now()
    const event = await plugin.fire("permission.evaluate", {
      sessionID: "ses_x", action: A.PROBE_ACTION, resources: ["*"], effect: "ask", metadata: { delayMs: 120, effect: "deny" },
    })
    expect(Date.now() - started).toBeGreaterThanOrEqual(100)
    expect(event.effect).toBe("deny")
    await plugin.dispose()
  })

})

describe("thread_interrupt", () => {
  test("same project: no approval, attributed, noted in the target, held", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller", title: "Caller" })
    plugin.add({ id: "ses_target", title: "Target", time: running })
    const result = await plugin.run("thread_interrupt", { threadID: "ses_target", reason: "it edits the same file" })
    expect((plugin.calls as any).asserts ?? []).toEqual([])
    expect(result.metadata.interrupt.by).toBe("ses_caller")
    expect(result.metadata.interrupt.actual).toBe("stopped")
    expect(result.content).toContain("Requested: stop. Actual: stopped")
    expect(plugin.sessions.get("ses_target")!.metadata!.bellocode_interrupt).toMatchObject({ held: true, reason: "it edits the same file" })
    expect(plugin.calls.synthetic[0]).toMatchObject({ sessionID: "ses_target", resume: false })
    expect(plugin.calls.synthetic[0].text).toContain("“Caller” (ses_caller)")
    await plugin.dispose()
  })

  test("a reason is required", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_target", time: running })
    await expect(plugin.run("thread_interrupt", { threadID: "ses_target" })).rejects.toThrow("Give a reason")
    await plugin.dispose()
  })

  test("deleted targets are refused; idle targets are reported, not interrupted", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_idle", time: idle })
    await expect(plugin.run("thread_interrupt", { threadID: "ses_gone", reason: "x" })).rejects.toThrow("Thread not found")
    const result = await plugin.run("thread_interrupt", { threadID: "ses_idle", reason: "x" })
    expect(result.metadata.interrupt.actual).toBe("not_running")
    expect(plugin.calls.interrupts).toEqual([])
    await plugin.dispose()
  })

  test("another project still asks (bellocode_other_project)", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_far", projectID: "p2", location: { directory: "/other" }, time: running })
    await plugin.run("thread_interrupt", { threadID: "ses_far", reason: "x" })
    expect(((plugin.calls as any).asserts ?? []).map((item: any) => item.action)).toEqual(["bellocode_other_project"])
    await plugin.dispose()
  })

  test("rate limit per target, and concurrent requests are de-duplicated", async () => {
    let release: () => void = () => undefined
    const gate = new Promise<void>((resolve) => (release = resolve))
    const plugin = await makePlugin({
      sessionInterrupt: async (input, sessions) => {
        await gate
        const found = sessions.get(input.sessionID)
        if (found) found.time = { ...found.time, idle: (found.time.busy ?? 0) + 1 }
      },
    })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_b" })
    plugin.add({ id: "ses_target", time: running })
    const first = plugin.run("thread_interrupt", { threadID: "ses_target", reason: "one" })
    const second = plugin.run("thread_interrupt", { threadID: "ses_target", reason: "two" }, "ses_b")
    await new Promise((resolve) => setTimeout(resolve, 20))
    release()
    const [a, b] = await Promise.all([first, second])
    expect(a.metadata.interrupt.actual).toBe("stopped")
    expect(b.metadata.deduplicated).toBe(true)
    expect(plugin.calls.interrupts.length).toBe(1)
    // The target is busy again; a third agent interrupting it within the window hits the limit (2 per target by default).
    plugin.sessions.get("ses_target")!.time = { ...running }
    await plugin.run("thread_interrupt", { threadID: "ses_target", reason: "three" }, "ses_b")
    plugin.sessions.get("ses_target")!.time = { ...running }
    await expect(plugin.run("thread_interrupt", { threadID: "ses_target", reason: "four" }, "ses_b")).rejects.toThrow("Rate limit")
    await plugin.dispose()
  })

  test("thread_send to a held thread is queued, never steered", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({
      id: "ses_target",
      time: idle,
      metadata: { bellocode_interrupt: { held: true, by: "x", reason: "r", at: 1, requested: "stop", actual: "stopped" } },
    })
    const result = await plugin.run("thread_send", { threadID: "ses_target", message: "hi", delivery: "steer" })
    expect(plugin.calls.prompts[0].delivery).toBe("queue")
    // GF02: admitted without waking it; a run would deliver the parked queue and clear the hold.
    expect(plugin.calls.prompts[0].resume).toBe(false)
    expect(result.content).toContain("waits until the user resumes")
    await plugin.dispose()
  })

  test("thread_send to a thread that is not held wakes it as usual", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_target", time: idle })
    await plugin.run("thread_send", { threadID: "ses_target", message: "hi" })
    expect(plugin.calls.prompts[0].delivery).toBe("queue")
    expect("resume" in plugin.calls.prompts[0]).toBe(false)
    await plugin.dispose()
  })
})
