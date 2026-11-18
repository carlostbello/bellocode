import { describe, expect, test } from "bun:test"
import { idle, makePlugin, running } from "./fake-context.ts"

// Deep review 1, C10: a stop reports what actually stopped, never what it merely attempted.
describe("task_cancel and thread_interrupt", () => {
  test("a failed interrupt is reported as failed, not stopped", async () => {
    const plugin = await makePlugin({
      sessionInterrupt: async (input, sessions) => {
        if (input.sessionID === "ses_b") throw new Error("server busy")
        const found = sessions.get(input.sessionID)
        if (found) found.time = { ...found.time, idle: 99 }
      },
    })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_task", parentID: "ses_caller", time: running })
    plugin.add({ id: "ses_a", parentID: "ses_task", time: running })
    plugin.add({ id: "ses_b", parentID: "ses_task", time: running })
    const result = await plugin.run("task_cancel", { taskID: "ses_task" })
    const report = result.metadata.stop
    expect(report.requested).toEqual(["ses_b", "ses_a", "ses_task"])
    expect(report.acknowledged).toEqual(["ses_a", "ses_task"])
    expect(report.failed.map((item: any) => item.id)).toEqual(["ses_b"])
    expect(report.settled.sort()).toEqual(["ses_a", "ses_task"])
    expect(report.complete).toBe(true)
    expect(result.content).toContain("Stopped ses_task")
    expect(result.content).toContain("1 of 2 running task(s) below it stopped")
    expect(result.content).toContain("failed to stop: ses_b")
    await plugin.dispose()
  })

  test("an acknowledged interrupt that does not settle is still stopping", async () => {
    const plugin = await makePlugin({ sessionInterrupt: async () => undefined })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_task", parentID: "ses_caller", time: idle })
    plugin.add({ id: "ses_a", parentID: "ses_task", time: running })
    const result = await plugin.run("task_cancel", { taskID: "ses_task" })
    expect(result.metadata.stop.stillRunning).toEqual(["ses_a"])
    expect(result.content).toContain("0 of 1 running task(s) below it stopped; still stopping: ses_a")
    await plugin.dispose()
  }, 15_000)

  test("children beyond the first page are found and stopped", async () => {
    const plugin = await makePlugin({
      // Two pages of children under ses_task; the running one is on the second page.
      sessionList: async (input, sessions) => {
        const all = [...sessions.values()].filter((item) => item.parentID === input.parentID)
        const start = input.cursor ? Number(input.cursor) : 0
        const page = all.slice(start, start + input.limit)
        const next = start + input.limit < all.length ? String(start + input.limit) : null
        return { data: page.map((item) => structuredClone(item)), cursor: { next } }
      },
    })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_task", parentID: "ses_caller", time: idle })
    for (let index = 0; index < 200; index++) plugin.add({ id: `ses_old${index}`, parentID: "ses_task", time: idle })
    plugin.add({ id: "ses_late", parentID: "ses_task", time: running })
    const result = await plugin.run("task_cancel", { taskID: "ses_task" })
    expect(result.metadata.stop.requested).toContain("ses_late")
    expect(result.metadata.stop.settled).toContain("ses_late")
    expect(result.metadata.stop.complete).toBe(true)
    await plugin.dispose()
  })

  test("a list that fails is reported as unexamined, not as an empty tree", async () => {
    const plugin = await makePlugin({
      sessionList: async (input, sessions) => {
        if (input.parentID === "ses_a") throw new Error("list failed")
        const all = [...sessions.values()].filter((item) => item.parentID === input.parentID)
        return { data: all.map((item) => structuredClone(item)) }
      },
    })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_task", parentID: "ses_caller", time: running })
    plugin.add({ id: "ses_a", parentID: "ses_task", time: running })
    plugin.add({ id: "ses_hidden", parentID: "ses_a", time: running })
    const result = await plugin.run("thread_interrupt", { threadID: "ses_task", reason: "test" })
    expect(result.metadata.stop.complete).toBe(false)
    expect(result.metadata.stop.unexamined).toBe(1)
    expect(result.content).toContain("not fully examined")
    await plugin.dispose()
  })
})

describe("thread_wait", () => {
  test("a tree that cannot be fully listed is never reported settled", async () => {
    const plugin = await makePlugin({
      sessionList: async (input, sessions) => {
        if (input.parentID === "ses_a") throw new Error("list failed")
        const all = [...sessions.values()].filter((item) => item.parentID === input.parentID)
        return { data: all.map((item) => structuredClone(item)) }
      },
    })
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_other", time: idle })
    plugin.add({ id: "ses_a", parentID: "ses_other", time: idle })
    const result = await plugin.run("thread_wait", { threadID: "ses_other", timeoutSeconds: 1 })
    const output = JSON.parse(result.content)
    expect(output.settled).toBe(false)
    expect(output.note).toContain("could not be confirmed idle")
    await plugin.dispose()
  }, 15_000)

  test("an idle, fully listed tree settles at once", async () => {
    const plugin = await makePlugin()
    plugin.add({ id: "ses_caller" })
    plugin.add({ id: "ses_other", time: idle })
    plugin.add({ id: "ses_a", parentID: "ses_other", time: idle })
    const result = await plugin.run("thread_wait", { threadID: "ses_other", timeoutSeconds: 1 })
    expect(JSON.parse(result.content).settled).toBe(true)
    await plugin.dispose()
  })
})
