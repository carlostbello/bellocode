import { describe, expect, test } from "bun:test"
import * as P from "../src/project.ts"
import { linkSync, mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"

/** An in-memory file system without links: paths ending in "/" are folders. */
function memoryFS(files: Record<string, string>, folders: string[] = []): P.FS {
  const dirs = new Set<string>(folders)
  for (const path of Object.keys(files)) {
    let current = path
    while (current.includes("/")) {
      current = current.slice(0, current.lastIndexOf("/")) || "/"
      dirs.add(current)
      if (current === "/") break
    }
  }
  return {
    kind: (path) => (path in files ? "file" : dirs.has(path) ? "directory" : undefined),
    realpath: (path) => (path in files || dirs.has(path) ? path : undefined),
    list: (path) =>
      [...new Set([...Object.keys(files), ...dirs].filter((p) => p.startsWith(path + "/") && !p.slice(path.length + 1).includes("/")).map((p) => p.slice(path.length + 1)))].sort(),
    readRegular: (path, limit) => (path in files ? { text: files[path].slice(0, limit), size: files[path].length } : undefined),
  }
}

describe("options and trust", () => {
  test("options need a known mode", () => {
    expect(P.projectConfigOptions({ projectConfig: { mode: "bellocode", trustFile: "/t.json" } })).toEqual({ mode: "bellocode", trustFile: "/t.json" })
    expect(P.projectConfigOptions({ projectConfig: { mode: "other" } })).toBeUndefined()
    expect(P.projectConfigOptions(undefined)).toBeUndefined()
  })

  test("trust is a list of project folders; a bad file trusts nothing", () => {
    const fs = memoryFS({ "/t.json": JSON.stringify({ version: 1, trusted: ["/r/a", 3] }), "/bad.json": "{" })
    expect(P.readTrust("/t.json", fs)).toEqual(["/r/a"])
    expect(P.readTrust("/bad.json", fs)).toEqual([])
    expect(P.readTrust(undefined, fs)).toEqual([])
    expect(P.isTrusted("/r/a/web", ["/r/a"])).toBe(true)
    expect(P.isTrusted("/r/ab", ["/r/a"])).toBe(false)
  })
})

describe("repository AGENTS.md", () => {
  const fs = memoryFS({
    "/r/app/.git": "gitdir",
    "/r/app/AGENTS.md": "root rules",
    "/r/app/web/AGENTS.md": "web rules",
    "/r/AGENTS.md": "outside the repository",
  })

  test("files from the repository root down to the directory, outer first; nothing above the root", () => {
    const files = P.instructionFiles("/r/app/web", fs)
    expect(files.map((file) => file.path)).toEqual(["/r/app/AGENTS.md", "/r/app/web/AGENTS.md"])
    expect(P.instructionsText(files)).toBe("Instructions from: /r/app/AGENTS.md\nroot rules\n\nInstructions from: /r/app/web/AGENTS.md\nweb rules")
  })

  test("no files, no entry; a missing directory is empty", () => {
    expect(P.instructionsText([])).toBeUndefined()
    expect(P.instructionFiles("/nowhere", fs)).toEqual([])
  })

  test("large files are truncated and the total is bounded", () => {
    const big = memoryFS({ "/b/.git": "x", "/b/AGENTS.md": "a".repeat(P.LIMITS.fileBytes + 10) })
    const [file] = P.instructionFiles("/b", big)
    expect(file.content.endsWith("[truncated by BelloCode: file too large]")).toBe(true)
  })
})

describe("frontmatter and specs", () => {
  test("flat keys parse; nested keys are reported", () => {
    const parsed = P.parseFrontmatter("---\ndescription: \"Reviews code\"\nmode: subagent\nsteps: 4\nhidden: false\n---\nYou review.\n")
    expect(parsed?.data).toEqual({ description: "Reviews code", mode: "subagent", steps: 4, hidden: false })
    expect(parsed?.body).toBe("You review.")
    expect(P.parseFrontmatter("---\npermission:\n  edit: deny\n---\nx")?.nested).toEqual(["permission"])
    expect(P.parseFrontmatter("---\nbroken\n---\nx")).toBeUndefined()
    expect(P.parseFrontmatter("no frontmatter")?.body).toBe("no frontmatter")
  })

  test("agents: model reference, mode check, unsupported fields refused", () => {
    expect(P.agentFromMarkdown("rev", "---\nmode: subagent\nmodel: openai/gpt-5#high\n---\nBody")).toEqual({
      id: "rev", system: "Body", mode: "subagent", model: { providerID: "openai", id: "gpt-5", variant: "high" },
    })
    expect(P.agentFromMarkdown("x", "---\nmode: boss\n---\nb")).toBe('unknown mode "boss"')
    expect(typeof P.agentFromMarkdown("x", "---\ntools:\n  bash: false\n---\nb")).toBe("string")
  })

  test("skills need a valid name and a description", () => {
    expect(P.skillFromMarkdown("/s/SKILL.md", "deploy", "---\ndescription: Deploys\n---\nSteps")).toEqual({
      id: "deploy", name: "deploy", description: "Deploys", path: "/s/SKILL.md", content: "Steps",
    })
    expect(P.skillFromMarkdown("/s/SKILL.md", "Bad Name", "---\ndescription: d\n---\nx")).toContain("lowercase")
    expect(P.skillFromMarkdown("/s/SKILL.md", "ok", "---\nname: ok\n---\nx")).toBe("missing description")
  })

  test("command templates expand like opencode's", () => {
    expect(P.expandTemplate("Fix $ARGUMENTS now", "the bug")).toBe("Fix the bug now")
    expect(P.expandTemplate("From $1 to $2", "a b c")).toBe("From a to b c")
    expect(P.expandTemplate("Review", "src/x.ts")).toBe("Review src/x.ts")
    expect(P.expandTemplate("Say $1", "")).toBe("Say")
  })
})

describe("trusted project configuration", () => {
  const fs = memoryFS({
    "/r/app/.git": "x",
    "/r/app/.opencode/agents/reviewer.md": "---\ndescription: Reviews\nmode: subagent\n---\nYou review.",
    "/r/app/.opencode/agents/nested/deep.md": "---\ndescription: Deep\n---\nDeep.",
    "/r/app/.opencode/agents/bad.md": "---\npermission:\n  edit: deny\n---\nx",
    "/r/app/.opencode/commands/ship.md": "---\ndescription: Ship it\n---\nShip $ARGUMENTS",
    "/r/app/.opencode/skills/deploy/SKILL.md": "---\nname: deploy\ndescription: Deploys\n---\nSteps",
    "/r/app/.agents/skills/lint/SKILL.md": "---\nname: lint\ndescription: Lints\n---\nRun lint",
  }, ["/r/app/web"])

  test("untrusted projects load nothing", () => {
    expect(P.loadProjectConfig("/r/app", [], fs)).toEqual(P.EMPTY)
  })

  test("trusted projects load agents, commands and skills; bad files are reported, not fatal", () => {
    const loaded = P.loadProjectConfig("/r/app/web", ["/r/app"], fs)
    expect(loaded.trusted).toBe(true)
    expect(loaded.agents.map((agent) => agent.id).sort()).toEqual(["nested/deep", "reviewer"])
    expect(loaded.commands).toEqual([{ name: "ship", description: "Ship it", template: "Ship $ARGUMENTS" }])
    expect(loaded.skills.map((skill) => skill.id)).toEqual(["deploy", "lint"])
    expect(loaded.skipped.length).toBe(1)
    expect(loaded.skipped[0]).toContain(".opencode/agents/bad.md")
  })
})

// Real files, links and FIFOs (A01/N01, A11): the reader must stay inside the repository and never block.
describe("untrusted repository contents on a real file system", () => {
  const made: string[] = []
  const scratch = () => {
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "bc-project-")))
    made.push(dir)
    return dir
  }
  const cleanup = () => {
    for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
  }

  test("an AGENTS.md link to a file outside the repository is never read", () => {
    const base = scratch()
    writeFileSync(join(base, "private.txt"), "HOST-SECRET-MARKER")
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    symlinkSync(join(base, "private.txt"), join(repo, "AGENTS.md"))
    const text = P.instructionsText(P.instructionFiles(repo)) ?? ""
    expect(text).not.toContain("HOST-SECRET-MARKER")
    expect(P.instructionFiles(repo)).toEqual([])
    cleanup()
  })

  test("AF08: an ancestor replaced by a link between the check and the open is refused, not followed", () => {
    const base = scratch()
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    mkdirSync(join(repo, "web"), { recursive: true })
    writeFileSync(join(repo, "web", "AGENTS.md"), "web rules")
    mkdirSync(join(base, "outside"))
    writeFileSync(join(base, "outside", "AGENTS.md"), "HOST-SECRET-MARKER")
    // The repository's web/ is swapped for a link to the outside folder just before the open (after the realpath
    // check), as a concurrent checkout or a hostile tool would.
    let swapped = false
    const racing: P.FS = {
      ...P.nodeFS,
      readRegular: (path, limit, root) => {
        if (!swapped && path.endsWith(join("web", "AGENTS.md"))) {
          swapped = true
          renameSync(join(repo, "web"), join(repo, "web-moved"))
          symlinkSync(join(base, "outside"), join(repo, "web"))
        }
        return P.nodeFS.readRegular(path, limit, root)
      },
    }
    const read = P.readInside(repo, join(repo, "web", "AGENTS.md"), P.LIMITS.fileBytes, racing)
    expect(swapped).toBe(true)
    expect(JSON.stringify(read)).not.toContain("HOST-SECRET-MARKER")
    expect("refused" in read).toBe(true)
    // An untouched file is still read through the same confined open.
    expect(P.readInside(repo, join(repo, "web-moved", "AGENTS.md"), P.LIMITS.fileBytes)).toEqual({ text: "web rules", size: 9 })
    cleanup()
  })

  test("AF08: a link present only at the open is refused even when every path check sees real folders", () => {
    // The race a path-based check cannot close: web/ is a real folder whenever it is examined itself, but a link to an
    // outside folder whenever a path *through* it is resolved (the leaf checks and the open). Every lstat then agrees
    // (the leaf check sees the outside file's identity, which is also what a following open would hold), so only an
    // open that refuses links in every component (O_NOFOLLOW_ANY / a descriptor chain) stops it.
    const base = scratch()
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    mkdirSync(join(repo, "web"), { recursive: true })
    writeFileSync(join(repo, "web", "AGENTS.md"), "web rules")
    mkdirSync(join(base, "outside"))
    writeFileSync(join(base, "outside", "AGENTS.md"), "HOST-SECRET-MARKER")
    const web = join(repo, "web")
    let linked = false
    const toLink = () => {
      if (linked) return
      renameSync(web, join(repo, "web-real"))
      symlinkSync(join(base, "outside"), web)
      linked = true
    }
    const toFolder = () => {
      if (!linked) return
      rmSync(web)
      renameSync(join(repo, "web-real"), web)
      linked = false
    }
    let opened = false
    const hooks: P.ConfinedReadHooks = {
      beforeCheck: (path) => (path === web ? toFolder() : toLink()),
      beforeOpen: () => {
        toLink()
        opened = true
      },
    }
    const read = P.readConfined(repo, join(web, "AGENTS.md"), P.LIMITS.fileBytes, hooks)
    toFolder()
    expect(opened).toBe(true)
    expect(read).toBeUndefined()
    // With no interference the same confined read returns the repository's own file.
    expect(P.readConfined(repo, join(web, "AGENTS.md"), P.LIMITS.fileBytes)).toEqual({ text: "web rules", size: 9 })
    cleanup()
  })

  test("AF08: a folder replaced between the open and the final check is refused", () => {
    const base = scratch()
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    mkdirSync(join(repo, "web"), { recursive: true })
    writeFileSync(join(repo, "web", "AGENTS.md"), "web rules")
    const read = P.readConfined(repo, join(repo, "web", "AGENTS.md"), P.LIMITS.fileBytes, {
      afterOpen: () => {
        renameSync(join(repo, "web"), join(repo, "web-old"))
        mkdirSync(join(repo, "web"))
        writeFileSync(join(repo, "web", "AGENTS.md"), "other")
      },
    })
    expect(read).toBeUndefined()
    cleanup()
  })

  test("AF08: a hard-linked instruction file is refused (its other name can be outside the repository)", () => {
    const base = scratch()
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    writeFileSync(join(base, "private.txt"), "HOST-SECRET-MARKER")
    linkSync(join(base, "private.txt"), join(repo, "AGENTS.md"))
    expect(P.readConfined(repo, join(repo, "AGENTS.md"), P.LIMITS.fileBytes)).toBeUndefined()
    expect(P.instructionFiles(repo)).toEqual([])
    cleanup()
  })

  test("an AGENTS.md link inside the repository is read (AGENTS.md -> CLAUDE.md)", () => {
    const repo = scratch()
    mkdirSync(join(repo, ".git"))
    writeFileSync(join(repo, "CLAUDE.md"), "repo rules")
    symlinkSync("CLAUDE.md", join(repo, "AGENTS.md"))
    expect(P.instructionFiles(repo).map((file) => file.content)).toEqual(["repo rules"])
    cleanup()
  })

  test("a FIFO named AGENTS.md is skipped without blocking", () => {
    const repo = scratch()
    mkdirSync(join(repo, ".git"))
    const made = Bun.spawnSync(["mkfifo", join(repo, "AGENTS.md")])
    expect(made.exitCode).toBe(0)
    const started = Date.now()
    expect(P.instructionFiles(repo)).toEqual([])
    expect(Date.now() - started).toBeLessThan(5_000)
    cleanup()
  })

  test("an oversized AGENTS.md is read only up to the limit", () => {
    const repo = scratch()
    mkdirSync(join(repo, ".git"))
    writeFileSync(join(repo, "AGENTS.md"), "a".repeat(P.LIMITS.fileBytes) + "TAIL-MARKER" + "b".repeat(P.LIMITS.fileBytes))
    let largest = 0
    const counting: P.FS = {
      ...P.nodeFS,
      readRegular: (path, limit) => {
        const read = P.nodeFS.readRegular(path, limit)
        largest = Math.max(largest, read?.text.length ?? 0)
        return read
      },
    }
    const [file] = P.instructionFiles(repo, counting)
    expect(file.content).not.toContain("TAIL-MARKER")
    expect(file.content.endsWith("[truncated by BelloCode: file too large]")).toBe(true)
    expect(largest).toBeLessThanOrEqual(P.LIMITS.fileBytes)
    cleanup()
  })

  test("trusted .opencode: a folder link loop and links leaving the repository are refused, not fatal", () => {
    const base = scratch()
    writeFileSync(join(base, "outside.md"), "---\ndescription: Outside\n---\nHOST-SECRET-MARKER")
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    mkdirSync(join(repo, ".opencode", "agents"), { recursive: true })
    writeFileSync(join(repo, ".opencode", "agents", "ok.md"), "---\ndescription: Fine\n---\nFine.")
    symlinkSync("..", join(repo, ".opencode", "agents", "loop"))
    symlinkSync(join(base, "outside.md"), join(repo, ".opencode", "agents", "stolen.md"))
    mkdirSync(join(repo, ".opencode", "skills", "leak"), { recursive: true })
    symlinkSync("/etc/hosts", join(repo, ".opencode", "skills", "leak", "SKILL.md"))
    const loaded = P.loadProjectConfig(repo, [repo])
    expect(loaded.trusted).toBe(true)
    expect(loaded.agents.map((agent) => agent.id)).toContain("ok")
    expect(JSON.stringify(loaded)).not.toContain("HOST-SECRET-MARKER")
    expect(loaded.skills).toEqual([])
    expect(loaded.skipped.some((line) => line.includes("stolen.md") && line.includes("outside the repository"))).toBe(true)
    cleanup()
  })

  test("trust does not cross into an independent repository nested in a trusted one", () => {
    const outer = scratch()
    mkdirSync(join(outer, ".git"))
    mkdirSync(join(outer, ".opencode", "commands"), { recursive: true })
    writeFileSync(join(outer, ".opencode", "commands", "outer.md"), "Outer $ARGUMENTS")
    const inner = join(outer, "vendor", "inner")
    mkdirSync(join(inner, ".git"), { recursive: true })
    mkdirSync(join(inner, ".opencode", "commands"), { recursive: true })
    writeFileSync(join(inner, ".opencode", "commands", "inner.md"), "Inner $ARGUMENTS")
    expect(P.loadProjectConfig(join(outer, "vendor"), [outer]).commands.map((c) => c.name)).toEqual(["outer"])
    expect(P.loadProjectConfig(inner, [outer])).toEqual(P.EMPTY)
    expect(P.loadProjectConfig(inner, [outer, inner]).commands.map((c) => c.name)).toEqual(["inner"])
    cleanup()
  })
})

describe("identity-bound instruction lookup (AF08, round 4)", () => {
  test("a pinned identity must be the very root folder, before and after the reads", () => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-identity-")))
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    writeFileSync(join(repo, "AGENTS.md"), "repo rules")
    const found = P.instructionLookup(repo)
    expect(found?.root).toBe(repo)
    expect(found?.identity).toEqual(P.folderIdentity(repo))
    expect(P.instructionLookup(repo, P.nodeFS, repo, found!.identity)?.files.map((f) => f.content)).toEqual(["repo rules"])
    // Same path, another folder: refused.
    renameSync(repo, join(base, "repo-moved"))
    mkdirSync(join(repo, ".git"), { recursive: true })
    writeFileSync(join(repo, "AGENTS.md"), "OTHER-MARKER")
    expect(P.instructionLookup(repo, P.nodeFS, repo, found!.identity)).toBeUndefined()
    // A confined read bound to an identity refuses a root with another one.
    expect(P.readConfined(repo, join(repo, "AGENTS.md"), 1024, undefined, found!.identity)).toBeUndefined()
    expect(P.readConfined(repo, join(repo, "AGENTS.md"), 1024, undefined, P.folderIdentity(repo))?.text).toBe("OTHER-MARKER")
    // A file system that cannot report identities cannot honour a pin: refused.
    const memory = memoryFS({ "/r/.git/HEAD": "x", "/r/AGENTS.md": "rules" })
    expect(P.instructionLookup("/r", memory, "/r")?.files.length).toBe(1)
    expect(P.instructionLookup("/r", memory, "/r", { dev: "1", ino: "2" })).toBeUndefined()
    rmSync(base, { recursive: true, force: true })
  })

  test("an unlinked lookup refuses a session folder reached through any link, even one above every checkout", () => {
    const base = realpathSync(mkdtempSync(join(tmpdir(), "bc-unlinked-")))
    const repo = join(base, "repo")
    mkdirSync(join(repo, ".git"), { recursive: true })
    writeFileSync(join(repo, "AGENTS.md"), "repo rules")
    const alias = join(base, "alias")
    symlinkSync(repo, alias)
    expect(P.instructionLookup(repo, P.nodeFS, undefined, undefined, true)?.files.map((f) => f.content)).toEqual(["repo rules"])
    expect(P.instructionLookup(`${repo}/`, P.nodeFS, undefined, undefined, true)?.root).toBe(repo)
    // Followed when the session is new (the person's own layout), refused when nothing says where it used to lead.
    expect(P.instructionLookup(alias)?.root).toBe(repo)
    expect(P.instructionLookup(alias, P.nodeFS, undefined, undefined, true)).toBeUndefined()
    rmSync(base, { recursive: true, force: true })
  })
})
