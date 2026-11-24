// The plugin's repository-configuration wiring (server.ts) against real files: setup survives hostile trees (N01),
// the prompt hook keeps instructions on a failed lookup (N22), and trust reloads report what really applied (A10).
import { describe, expect, test } from "bun:test"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"
import { makePlugin } from "./fake-context.ts"
import { PinStore } from "../src/pins.ts"

function repository() {
  const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-plugin-")))
  const repo = join(base, "repo")
  mkdirSync(join(repo, ".git"), { recursive: true })
  mkdirSync(join(repo, ".opencode", "commands"), { recursive: true })
  mkdirSync(join(repo, ".opencode", "agents"), { recursive: true })
  writeFileSync(join(repo, ".opencode", "commands", "ship.md"), "Ship $ARGUMENTS")
  writeFileSync(join(repo, "AGENTS.md"), "repo rules")
  const trustFile = join(base, "trust.json")
  const trust = (trusted: string[], revision: number) => writeFileSync(trustFile, JSON.stringify({ version: 1, revision, trusted }))
  // The app's pin folder (OpenCodeDirectories.instructionPinsDirectory): outside every checkout.
  const pinDirectory = join(base, "app-data", "bellocode-instruction-pins")
  const options = () => ({ projectConfig: { mode: "bellocode", trustFile, pinDirectory } })
  return { base, repo, trustFile, trust, pinDirectory, options, cleanup: () => rmSync(base, { recursive: true, force: true }) }
}

describe("repository configuration in the plugin", () => {
  test("a folder link loop in a trusted repository does not stop setup or the container guard", async () => {
    const r = repository()
    symlinkSync("..", join(r.repo, ".opencode", "agents", "loop"))
    symlinkSync(join(r.repo, ".opencode", "agents"), join(r.repo, ".opencode", "agents", "self"))
    r.trust([r.repo], 1)
    const plugin = await makePlugin(
      { location: r.repo },
      { ...r.options(), container: { helper: "/h/bellocode-exec", config: "/h/exec.json" } },
    )
    expect(plugin.hooks["shell.create.before"]?.length).toBe(1)
    expect(plugin.hooks["permission.evaluate"]?.length ?? 0).toBeGreaterThan(0)
    expect(plugin.calls.transforms.command.map((item: any) => item.name)).toEqual(["ship"])
    r.cleanup()
  })

  test("a failed session lookup leaves the instruction entry alone", async () => {
    const r = repository()
    let failLookup = false
    const plugin = await makePlugin(
      {
        location: r.repo,
        sessionGet: async ({ sessionID }, sessions) => {
          if (failLookup) throw new Error("transient")
          return { data: sessions.get(sessionID) }
        },
      },
      r.options(),
    )
    plugin.add({ id: "ses_1", location: { directory: r.repo } })
    await plugin.fire("session.prompt", { sessionID: "ses_1" })
    expect(plugin.calls.instructions).toEqual([{ op: "put", sessionID: "ses_1", value: `Instructions from: ${join(r.repo, "AGENTS.md")}\nrepo rules` }])
    failLookup = true
    await plugin.fire("session.prompt", { sessionID: "ses_1" })
    expect(plugin.calls.instructions.filter((call) => call.op === "remove")).toEqual([])
    r.cleanup()
  })

  // AF08: the prompt hook rediscovers the root at every prompt; a session folder that comes to point into another
  // checkout must not hand over that checkout's instructions, mid-session or on a fresh server.
  const instructionPlugin = async (r: ReturnType<typeof repository>, directory: string) => {
    const plugin = await makePlugin({ location: r.repo }, r.options())
    // Created after the plugin started: a new session, pinned as found (older ones: "durable repository-root pins").
    plugin.add({ id: "ses_sub", location: { directory }, time: { created: Date.now() + 1 } })
    return plugin
  }
  const values = (plugin: any) => plugin.calls.instructions.map((call: any) => call.value ?? `<${call.op}>`).join("\n")

  test("AF08: a subdirectory swapped for a link into a neighbouring checkout hands over nothing", async () => {
    const r = repository()
    const sub = join(r.repo, "sub")
    mkdirSync(sub)
    writeFileSync(join(sub, "AGENTS.md"), "sub rules")
    const neighbour = join(r.base, "neighbour")
    mkdirSync(join(neighbour, ".git"), { recursive: true })
    mkdirSync(join(neighbour, "sub"))
    writeFileSync(join(neighbour, "AGENTS.md"), "NEIGHBOUR-MARKER")
    writeFileSync(join(neighbour, "sub", "AGENTS.md"), "NEIGHBOUR-SUB-MARKER")
    const plugin = await instructionPlugin(r, sub)
    await plugin.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(plugin)).toContain("sub rules")
    // The agent replaces its own folder with a link to the neighbour (same name, so the paths still look alike).
    renameSync(sub, join(r.repo, "sub-moved"))
    symlinkSync(join(neighbour, "sub"), sub)
    await plugin.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(plugin)).not.toContain("NEIGHBOUR")
    expect(plugin.calls.instructions.at(-1)).toEqual({ op: "remove", sessionID: "ses_sub" })
    // A fresh server refuses it too, pinned or not: the link sits inside a checkout.
    const fresh = await instructionPlugin(r, sub)
    await fresh.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(fresh)).not.toContain("NEIGHBOUR")
    // So does a link to the neighbour's root.
    rmSync(sub)
    symlinkSync(neighbour, sub)
    const root = await instructionPlugin(r, sub)
    await root.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(root)).not.toContain("NEIGHBOUR")
    r.cleanup()
  })

  test("AF08: outside a checkout, a folder that comes to point elsewhere is refused mid-session and never leads into a checkout's middle", async () => {
    const r = repository()
    const work = join(r.base, "work")
    const sub = join(work, "sub")
    mkdirSync(sub, { recursive: true })
    writeFileSync(join(sub, "AGENTS.md"), "work rules")
    const other = join(r.base, "other")
    mkdirSync(other)
    writeFileSync(join(other, "AGENTS.md"), "OTHER-MARKER")
    const plugin = await instructionPlugin(r, sub)
    await plugin.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(plugin)).toContain("work rules")
    renameSync(sub, join(work, "sub-moved"))
    symlinkSync(other, sub)
    await plugin.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(plugin)).not.toContain("OTHER-MARKER")
    // A link into the middle of a checkout would read the checkout's upper instructions: refused even when fresh.
    rmSync(sub)
    const neighbour = join(r.base, "neighbour")
    mkdirSync(join(neighbour, ".git"), { recursive: true })
    mkdirSync(join(neighbour, "x"))
    writeFileSync(join(neighbour, "AGENTS.md"), "NEIGHBOUR-MARKER")
    symlinkSync(join(neighbour, "x"), sub)
    const fresh = await instructionPlugin(r, sub)
    await fresh.fire("session.prompt", { sessionID: "ses_sub" })
    expect(values(fresh)).not.toContain("NEIGHBOUR-MARKER")
    r.cleanup()
  })

  test("AF08: a link above every checkout (the person's own layout) still finds the repository", async () => {
    const r = repository()
    const alias = join(r.base, "alias")
    symlinkSync(r.repo, alias)
    const plugin = await instructionPlugin(r, alias)
    await plugin.fire("session.prompt", { sessionID: "ses_sub" })
    expect(plugin.calls.instructions).toEqual([
      { op: "put", sessionID: "ses_sub", value: `Instructions from: ${join(r.repo, "AGENTS.md")}\nrepo rules` },
    ])
    r.cleanup()
  })

  test("a trust reload reports the revision it read and any transform that failed", async () => {
    const r = repository()
    r.trust([r.repo], 4)
    const ok = await makePlugin({ location: r.repo }, r.options())
    r.trust([], 5)
    const status = await ok.rpc("projectConfig", { reload: true })
    expect(status).toMatchObject({ revision: 5, applied: true, failures: [], trusted: false, commands: [] })

    const failing = await makePlugin(
      { location: r.repo, failingReloads: ["command"] },
      r.options(),
    )
    const failed = await failing.rpc("projectConfig", { reload: true })
    expect(failed).toMatchObject({ revision: 5, applied: false, failures: ["commands"] })
    r.cleanup()
  })

  test("a project command refuses to run once its repository is no longer trusted", async () => {
    const r = repository()
    r.trust([r.repo], 1)
    const plugin = await makePlugin({ location: r.repo }, r.options())
    const ship = plugin.calls.transforms.command.find((item: any) => item.name === "ship")
    await ship.execute({ sessionID: "ses_1", prompt: { text: "it" } })
    expect(plugin.calls.prompts.map((p) => p.text)).toEqual(["Ship it"])
    r.trust([], 2)
    await expect(ship.execute({ sessionID: "ses_1", prompt: { text: "again" } })).rejects.toThrow("no longer trusts")
    expect(plugin.calls.prompts.length).toBe(1)
    r.cleanup()
  })
})

// AF08, round 4: a session's root pin outlives the server. Each `restart` loads a fresh copy of server.ts, so nothing
// the earlier server kept in memory survives; only the app's pin folder does.
describe("durable repository-root pins (AF08)", () => {
  /** A writable shared code root (outside any checkout) holding checkouts `a` and `b`. */
  function codeRoot() {
    const r = repository()
    const code = join(r.base, "code")
    const a = join(code, "a")
    const b = join(code, "b")
    for (const [checkout, text] of [
      [a, "A rules"],
      [b, "B-MARKER"],
    ]) {
      mkdirSync(join(checkout, ".git"), { recursive: true })
      writeFileSync(join(checkout, "AGENTS.md"), text)
    }
    return { ...r, code, a, b }
  }
  let restarts = 0
  const server = async (r: ReturnType<typeof codeRoot>, options: any = r.options()) =>
    makePlugin({ location: r.a, restart: `pins-${++restarts}` }, options)
  const values = (plugin: any) => plugin.calls.instructions.map((call: any) => call.value ?? `<${call.op}>`).join("\n")
  const puts = (plugin: any, sessionID: string) => plugin.calls.instructions.filter((call: any) => call.sessionID === sessionID && call.op === "put")
  /** A creation time after every server started so far: the session is new to the pin store. */
  const now = () => Date.now() + 1
  /** The folder `a` replaced by a link to `b` in the shared code root (the link's parent is outside any checkout). */
  const swapToLink = (r: ReturnType<typeof codeRoot>) => {
    renameSync(r.a, join(r.code, "a-moved"))
    symlinkSync(r.b, r.a)
  }

  test("a resumed session whose checkout folder became a link to another checkout gets no instructions after a restart", async () => {
    const r = codeRoot()
    const first = await server(r)
    const created = now()
    first.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    await first.fire("session.prompt", { sessionID: "ses_a" })
    expect(values(first)).toBe(`Instructions from: ${join(r.a, "AGENTS.md")}\nA rules`)
    expect(existsSync(join(r.pinDirectory, "ses_a.json"))).toBe(true)

    // While the server is down, the shared code root's entry for `a` is replaced by a link to `b`.
    swapToLink(r)
    const restarted = await server(r)
    restarted.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    await restarted.fire("session.prompt", { sessionID: "ses_a" })
    expect(values(restarted)).not.toContain("B-MARKER")
    expect(restarted.calls.instructions.at(-1)).toEqual({ op: "remove", sessionID: "ses_a" })
    // Its pin is kept as it was, so the next prompt refuses again rather than re-pinning to `b`.
    await restarted.fire("session.prompt", { sessionID: "ses_a" })
    expect(values(restarted)).not.toContain("B-MARKER")
    expect(JSON.parse(readFileSync(join(r.pinDirectory, "ses_a.json"), "utf8")).root).toBe(r.a)

    // A first-time session in a project the person adds still gets its instructions, and is pinned before it does.
    const fresh = await server(r)
    fresh.add({ id: "ses_b", location: { directory: r.b }, time: { created: now() } })
    await fresh.fire("session.prompt", { sessionID: "ses_b" })
    expect(values(fresh)).toBe(`Instructions from: ${join(r.b, "AGENTS.md")}\nB-MARKER`)
    expect(JSON.parse(readFileSync(join(r.pinDirectory, "ses_b.json"), "utf8")).root).toBe(r.b)
    r.cleanup()
  })

  test("a checkout moved away and replaced by another folder at the same path is refused by identity", async () => {
    const r = codeRoot()
    const first = await server(r)
    const created = now()
    first.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    await first.fire("session.prompt", { sessionID: "ses_a" })
    expect(values(first)).toContain("A rules")
    renameSync(r.a, join(r.code, "a-moved"))
    renameSync(r.b, r.a)
    const restarted = await server(r)
    restarted.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    await restarted.fire("session.prompt", { sessionID: "ses_a" })
    expect(values(restarted)).not.toContain("B-MARKER")
    r.cleanup()
  })

  test("a child or fork in the same folder keeps the pin of the session it came from", async () => {
    const r = codeRoot()
    const first = await server(r)
    const created = now()
    first.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    await first.fire("session.prompt", { sessionID: "ses_a" })
    swapToLink(r)
    const restarted = await server(r)
    restarted.add({ id: "ses_a", location: { directory: r.a }, time: { created } })
    restarted.add({ id: "ses_child", parentID: "ses_a", location: { directory: r.a }, time: { created: now() } })
    restarted.add({ id: "ses_fork", fork: { sessionID: "ses_a" }, location: { directory: r.a }, time: { created: now() } } as any)
    await restarted.fire("session.prompt", { sessionID: "ses_child" })
    await restarted.fire("session.prompt", { sessionID: "ses_fork" })
    expect(values(restarted)).not.toContain("B-MARKER")
    r.cleanup()
  })

  test("a session older than the pin store is pinned only when its folder's path holds no link", async () => {
    const r = codeRoot()
    // Sessions from before durable pins (their roots were pinned in memory only): created before the store existed.
    const older = Date.now() - 60_000
    swapToLink(r)
    const plugin = await server(r)
    plugin.add({ id: "ses_old_a", location: { directory: r.a }, time: { created: older } })
    plugin.add({ id: "ses_old_b", location: { directory: r.b }, time: { created: older } })
    await plugin.fire("session.prompt", { sessionID: "ses_old_a" })
    expect(puts(plugin, "ses_old_a")).toEqual([])
    expect(existsSync(join(r.pinDirectory, "ses_old_a.json"))).toBe(false)
    await plugin.fire("session.prompt", { sessionID: "ses_old_b" })
    expect(puts(plugin, "ses_old_b")).toEqual([{ op: "put", sessionID: "ses_old_b", value: `Instructions from: ${join(r.b, "AGENTS.md")}\nB-MARKER` }])
    expect(JSON.parse(readFileSync(join(r.pinDirectory, "ses_old_b.json"), "utf8")).root).toBe(r.b)

    // A new session reached through a link above every checkout (the person's own layout) is pinned as found.
    const alias = join(r.base, "alias")
    symlinkSync(r.code, alias)
    plugin.add({ id: "ses_alias", location: { directory: join(alias, "b") }, time: { created: now() } })
    plugin.add({ id: "ses_old_alias", location: { directory: join(alias, "b") }, time: { created: older } })
    await plugin.fire("session.prompt", { sessionID: "ses_alias" })
    expect(puts(plugin, "ses_alias").length).toBe(1)
    await plugin.fire("session.prompt", { sessionID: "ses_old_alias" })
    expect(puts(plugin, "ses_old_alias")).toEqual([])
    r.cleanup()
  })

  test("a session that may have lost its pin to eviction is held to a link-free folder; an unreadable pin or no pin folder gets nothing", async () => {
    const r = codeRoot()
    // An eviction recorded sessions created up to `evicted` (newer than the store's own first watermark).
    const evicted = Date.now() + 10_000
    mkdirSync(join(r.pinDirectory, "watermark"), { recursive: true })
    writeFileSync(join(r.pinDirectory, "watermark", String(evicted)), "")
    const plugin = await server(r)
    plugin.add({ id: "ses_evicted", location: { directory: r.a }, time: { created: evicted - 1 } })
    await plugin.fire("session.prompt", { sessionID: "ses_evicted" })
    expect(values(plugin)).toContain("A rules")
    swapToLink(r)
    plugin.add({ id: "ses_evicted_link", location: { directory: r.a }, time: { created: evicted - 1 } })
    plugin.add({ id: "ses_new", location: { directory: r.a }, time: { created: evicted + 1 } })
    await plugin.fire("session.prompt", { sessionID: "ses_evicted_link" })
    expect(puts(plugin, "ses_evicted_link")).toEqual([])
    expect(existsSync(join(r.pinDirectory, "ses_evicted_link.json"))).toBe(false)
    // Created after the watermark: new, pinned as found (here, through the link the person's layout now has).
    await plugin.fire("session.prompt", { sessionID: "ses_new" })
    expect(puts(plugin, "ses_new").length).toBe(1)

    writeFileSync(join(r.pinDirectory, "ses_bad.json"), "{ not json")
    plugin.add({ id: "ses_bad", location: { directory: r.b }, time: { created: now() } })
    await plugin.fire("session.prompt", { sessionID: "ses_bad" })
    expect(puts(plugin, "ses_bad")).toEqual([])
    expect(readFileSync(join(r.pinDirectory, "ses_bad.json"), "utf8")).toBe("{ not json")

    const unpinned = await server(r, { projectConfig: { mode: "bellocode", trustFile: r.trustFile } })
    unpinned.add({ id: "ses_none", location: { directory: r.b }, time: { created: now() } })
    await unpinned.fire("session.prompt", { sessionID: "ses_none" })
    expect(puts(unpinned, "ses_none")).toEqual([])
    r.cleanup()
  })

  test("session creation and each run refresh the pinned instructions instead of removing them", async () => {
    const r = codeRoot()
    const plugin = await server(r)
    plugin.add({ id: "ses_a", location: { directory: r.a }, time: { created: now() } })
    const settled = async (count: number) => {
      // The plugin handles events off the stream without awaiting them: wait for the writes they make (bounded).
      for (let turn = 0; turn < 1_000 && plugin.calls.instructions.length < count; turn++) await new Promise((done) => setImmediate(done))
      return plugin.calls.instructions
    }
    plugin.emit({ id: "evt_1", type: "session.created", data: { sessionID: "ses_a" } })
    const created = await settled(2)
    expect(created.length).toBe(2)
    expect(created.at(-1)).toEqual({ op: "put", sessionID: "ses_a", value: `Instructions from: ${join(r.a, "AGENTS.md")}\nA rules` })
    expect(existsSync(join(r.pinDirectory, "ses_a.json"))).toBe(true)
    writeFileSync(join(r.a, "AGENTS.md"), "A rules, revised")
    plugin.emit({ id: "evt_2", type: "session.execution.started", data: { sessionID: "ses_a" } })
    const started = await settled(3)
    expect(started.length).toBe(3)
    expect(started.at(-1)).toEqual({ op: "put", sessionID: "ses_a", value: `Instructions from: ${join(r.a, "AGENTS.md")}\nA rules, revised` })
    await plugin.dispose?.()
    r.cleanup()
  })
})

describe("PinStore", () => {
  const identity = { dev: "1", ino: "2" }

  test("a new store records its creation time as the first watermark, and never lowers it", () => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-pins-")))
    const store = new PinStore(join(base, "pins"), { pins: 2, keep: 1, fileBytes: 4096, pruneEvery: 1_000 })
    expect(store.initialise(5_000)).toBe(true)
    // Already recorded: a later start keeps it.
    expect(store.initialise(9_000)).toBe(true)
    expect(store.watermark()).toBe(5_000)
    for (const [index, created] of [10, 20, 30].entries()) {
      expect(store.write(`ses_${index + 1}`, { directory: "/r", root: "/r", identity, created })).toBe(true)
      utimesSync(join(base, "pins", `ses_${index + 1}.json`), index + 1, index + 1)
    }
    store.prune()
    expect(store.read("ses_1")).toBe("none")
    expect(store.read("ses_3")).toMatchObject({ created: 30 })
    expect(store.watermark()).toBe(5_000)
    // Markers removed by hand: the next read records a fresh one rather than treating every session as new.
    rmSync(join(base, "pins", "watermark"), { recursive: true, force: true })
    const before = Date.now()
    expect(store.watermark()).toBeGreaterThanOrEqual(before)
    rmSync(base, { recursive: true, force: true })
  })

  test("overflow records a watermark before removing the oldest pins", () => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-pins-")))
    const store = new PinStore(join(base, "pins"), { pins: 3, keep: 2, fileBytes: 4096, pruneEvery: 1 })
    expect(store.initialise(1)).toBe(true)
    for (const [index, created] of [10, 20, 30, 40].entries()) {
      expect(store.write(`ses_${index + 1}`, { directory: "/r", root: "/r", identity, created })).toBe(true)
      utimesSync(join(base, "pins", `ses_${index + 1}.json`), index + 1, index + 1)
    }
    store.prune()
    expect(store.read("ses_1")).toBe("none")
    expect(store.read("ses_2")).toBe("none")
    expect(store.read("ses_4")).toMatchObject({ root: "/r", created: 40 })
    expect(store.watermark()).toBe(20)
    expect(store.read("../escape")).toBe("unreadable")
    rmSync(base, { recursive: true, force: true })
  })

  test("a pin folder that is a link is not used", () => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-pins-")))
    mkdirSync(join(base, "elsewhere"))
    symlinkSync(join(base, "elsewhere"), join(base, "pins"))
    const store = new PinStore(join(base, "pins"))
    expect(store.initialise()).toBe(false)
    expect(store.read("ses_1")).toBe("unreadable")
    expect(store.write("ses_1", { directory: "/r", root: "/r", identity, created: 1 })).toBe(false)
    expect(store.watermark()).toBe(Infinity)
    rmSync(base, { recursive: true, force: true })
  })
})
