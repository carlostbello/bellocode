import { describe, expect, test } from "bun:test"
import * as L from "../src/logic.ts"

const session = (id: string, extra: Partial<L.SessionLike> = {}): L.SessionLike => ({ id, projectID: "p1", ...extra })
const running = { time: { created: 1, busy: 10, idle: 5 } }
const idle = { time: { created: 1, busy: 10, idle: 20 } }

describe("limits", () => {
  test("defaults and clamping", () => {
    expect(L.limitsFrom(undefined)).toEqual(L.DEFAULT_LIMITS)
    const limits = L.limitsFrom({ limits: { maxDepth: 99, maxCreate: 0, maxWaitSeconds: "x" } })
    expect(limits.maxDepth).toBe(5)
    expect(limits.maxCreate).toBe(1)
    expect(limits.maxWaitSeconds).toBe(L.DEFAULT_LIMITS.maxWaitSeconds)
  })
  test("depth and fan-out refusals name the limit", () => {
    const limits = L.DEFAULT_LIMITS
    expect(L.checkDelegate({ callerDepth: 0, activeChildren: 0, limits })).toBeUndefined()
    expect(L.checkDelegate({ callerDepth: 1, activeChildren: 0, limits })).toBeUndefined()
    expect(L.checkDelegate({ callerDepth: 2, activeChildren: 0, limits })).toContain("depth limit")
    expect(L.checkDelegate({ callerDepth: 0, activeChildren: 6, limits })).toContain("Too many running child tasks")
    expect(L.checkCreate(0, limits)).toBeDefined()
    expect(L.checkCreate(9, limits)).toContain("At most 8")
    expect(L.checkCreate(3, limits)).toBeUndefined()
  })
  test("wait is capped", () => {
    expect(L.clampWait(500, L.DEFAULT_LIMITS)).toBe(45)
    expect(L.clampWait(-3, L.DEFAULT_LIMITS)).toBe(0)
    expect(L.clampWait(undefined, L.DEFAULT_LIMITS)).toBe(45)
  })
})

describe("sessions", () => {
  test("running from busy and idle times", () => {
    expect(L.isRunning(session("a", running))).toBe(true)
    expect(L.isRunning(session("a", idle))).toBe(false)
    expect(L.isRunning(session("a", { time: { busy: 3 } }))).toBe(true)
    expect(L.isRunning(session("a"))).toBe(false)
  })
  test("depth counts ancestors", () => {
    expect(L.depthOf([session("a")])).toBe(0)
    expect(L.depthOf([session("c"), session("b"), session("a")])).toBe(2)
  })
  test("task state", () => {
    expect(L.taskState(session("t", running), [])).toBe("working")
    expect(L.taskState(session("t", idle), [session("c", running)])).toBe("waiting_for_children")
    expect(L.taskState(session("t", { ...idle, outcome: "succeeded" }), [])).toBe("result_available")
    expect(L.taskState(session("t", { ...idle, outcome: "failed" }), [])).toBe("failed")
    expect(L.taskState(session("t", { ...idle, outcome: "interrupted" }), [])).toBe("cancelled")
    expect(L.taskState(session("t", idle), [])).toBe("idle")
  })
  test("bellocode metadata", () => {
    expect(L.belloMeta(session("a"))).toEqual({})
    expect(L.belloMeta(session("a", { metadata: { bellocode: { kind: "delegated", by: "p" } } })).kind).toBe("delegated")
  })
})

describe("scoping", () => {
  const caller = session("caller")
  test("self, descendant, same project, other project", () => {
    expect(L.scopeOf(caller, caller, [])).toBe("self")
    expect(L.scopeOf(caller, session("child", { parentID: "caller" }), [caller])).toBe("descendant")
    expect(L.scopeOf(caller, session("g", { parentID: "child" }), [session("child"), caller])).toBe("descendant")
    expect(L.scopeOf(caller, session("sibling"), [])).toBe("same_project")
    expect(L.scopeOf(caller, session("far", { projectID: "p2" }), [])).toBe("other_project")
  })
})

describe("models", () => {
  test("parse refs and variants", () => {
    expect(L.parseModel("opencode/big-pickle")).toEqual({ providerID: "opencode", id: "big-pickle" })
    expect(L.parseModel("openai/gpt-x#high")).toEqual({ providerID: "openai", id: "gpt-x", variant: "high" })
    expect(L.parseModel("openai/gpt-x", "low")).toEqual({ providerID: "openai", id: "gpt-x", variant: "low" })
    expect(L.parseModel("nope")).toHaveProperty("error")
    expect(L.parseModel(undefined, "low")).toHaveProperty("error")
    expect(L.parseModel(undefined)).toBeUndefined()
  })
})

describe("text", () => {
  const messages: L.MessageLike[] = [
    { type: "user", text: "do it" },
    { type: "assistant", content: [{ type: "reasoning", text: "hmm" }, { type: "text", text: "first" }] },
    { type: "synthetic", text: "<subagent>…</subagent>" },
    { type: "assistant", content: [{ type: "tool", name: "read" }, { type: "text", text: "final answer" }] },
    { type: "assistant", content: [{ type: "tool", name: "glob" }] },
  ]
  test("last reply skips tool-only messages", () => {
    expect(L.lastReply(messages)).toBe("final answer")
    expect(L.lastReply([])).toBe("")
  })
  test("transcript is bounded, newest kept", () => {
    const all = L.renderTranscript(messages, { maxMessages: 50, maxChars: 10_000 })
    expect(all.truncated).toBe(false)
    expect(all.text).toContain("[tools] read")
    expect(all.text).not.toContain("hmm")
    const few = L.renderTranscript(messages, { maxMessages: 3, maxChars: 10_000 })
    expect(few.truncated).toBe(true)
    expect(few.text.startsWith("[assistant] final answer")).toBe(true)
    const short = L.renderTranscript(messages, { maxMessages: 50, maxChars: 20 })
    expect(short.text.length).toBe(20)
    expect(short.truncated).toBe(true)
  })
  test("clip and one line", () => {
    expect(L.clip("abcdef", 4)).toBe("abc…")
    expect(L.oneLine("a\n\n b   c", 10)).toBe("a b c")
  })
  test("guidance depends on depth", () => {
    expect(L.guidance({ depth: 0, limits: L.DEFAULT_LIMITS, delegated: false })).toContain("delegate_task starts")
    const leaf = L.guidance({ depth: 2, limits: L.DEFAULT_LIMITS, delegated: true })
    expect(leaf).toContain("cannot delegate further")
    expect(leaf).toContain("delegated child task")
    expect(leaf.length).toBeLessThan(1400)
  })
})
