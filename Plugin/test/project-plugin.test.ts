// The plugin's repository-configuration wiring (server.ts) against real files: setup survives hostile trees (N01),
// the prompt hook keeps instructions on a failed lookup (N22), and trust reloads report what really applied (A10).
import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"
import { makePlugin } from "./fake-context.ts"

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
  return { base, repo, trustFile, trust, cleanup: () => rmSync(base, { recursive: true, force: true }) }
}

describe("repository configuration in the plugin", () => {
  test("a folder link loop in a trusted repository does not stop setup or the container guard", async () => {
    const r = repository()
    symlinkSync("..", join(r.repo, ".opencode", "agents", "loop"))
    symlinkSync(join(r.repo, ".opencode", "agents"), join(r.repo, ".opencode", "agents", "self"))
    r.trust([r.repo], 1)
    const plugin = await makePlugin(
      { location: r.repo },
      { projectConfig: { mode: "bellocode", trustFile: r.trustFile }, container: { helper: "/h/bellocode-exec", config: "/h/exec.json" } },
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
      { projectConfig: { mode: "bellocode", trustFile: r.trustFile } },
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
    const plugin = await makePlugin({ location: r.repo }, { projectConfig: { mode: "bellocode", trustFile: r.trustFile } })
    plugin.add({ id: "ses_sub", location: { directory } })
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
    // A fresh server (no pin) refuses it too: the link sits inside a checkout.
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
    const ok = await makePlugin({ location: r.repo }, { projectConfig: { mode: "bellocode", trustFile: r.trustFile } })
    r.trust([], 5)
    const status = await ok.rpc("projectConfig", { reload: true })
    expect(status).toMatchObject({ revision: 5, applied: true, failures: [], trusted: false, commands: [] })

    const failing = await makePlugin(
      { location: r.repo, failingReloads: ["command"] },
      { projectConfig: { mode: "bellocode", trustFile: r.trustFile } },
    )
    const failed = await failing.rpc("projectConfig", { reload: true })
    expect(failed).toMatchObject({ revision: 5, applied: false, failures: ["commands"] })
    r.cleanup()
  })

  test("a project command refuses to run once its repository is no longer trusted", async () => {
    const r = repository()
    r.trust([r.repo], 1)
    const plugin = await makePlugin({ location: r.repo }, { projectConfig: { mode: "bellocode", trustFile: r.trustFile } })
    const ship = plugin.calls.transforms.command.find((item: any) => item.name === "ship")
    await ship.execute({ sessionID: "ses_1", prompt: { text: "it" } })
    expect(plugin.calls.prompts.map((p) => p.text)).toEqual(["Ship it"])
    r.trust([], 2)
    await expect(ship.execute({ sessionID: "ses_1", prompt: { text: "again" } })).rejects.toThrow("no longer trusts")
    expect(plugin.calls.prompts.length).toBe(1)
    r.cleanup()
  })
})
