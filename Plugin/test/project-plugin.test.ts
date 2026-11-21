// The plugin's repository-configuration wiring (server.ts) against real files: setup survives hostile trees (N01),
// the prompt hook keeps instructions on a failed lookup (N22), and trust reloads report what really applied (A10).
import { describe, expect, test } from "bun:test"
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs"
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
