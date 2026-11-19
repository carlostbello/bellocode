import { describe, expect, test } from "bun:test"
import * as P from "../src/project.ts"

/** An in-memory file system: paths ending in "/" are folders. */
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
    exists: (path) => path in files || dirs.has(path),
    isDirectory: (path) => dirs.has(path),
    read: (path) => files[path],
    list: (path) =>
      [...new Set([...Object.keys(files), ...dirs].filter((p) => p.startsWith(path + "/") && !p.slice(path.length + 1).includes("/")).map((p) => p.slice(path.length + 1)))].sort(),
    size: (path) => files[path]?.length ?? 0,
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
  })

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
