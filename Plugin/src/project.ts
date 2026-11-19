// Repository opencode configuration in BelloCode's default mode (docs/features/opencode-config.md).
//
// opencode reads its project-config switch once per server process, and BelloCode's server keeps it off
// (`OPENCODE_DISABLE_PROJECT_CONFIG=1`): a repository's opencode.json and plugins would run inside opencode on the Mac.
// That also drops the repository's AGENTS.md (measured on 2.3.2). This module gives that text back, per session,
// for every project, and, for projects the person trusts, loads the repository's `.opencode/` agents, commands and
// skills (text only; no opencode.json, no plugins). Pure functions over a small file-system interface, so the tests
// run without opencode.

import { existsSync, readFileSync, readdirSync, statSync } from "fs"
import { dirname, join, relative, sep } from "path"

export type ProjectConfigMode = "bellocode" | "native"
export type ProjectConfigOptions = { mode: ProjectConfigMode; trustFile?: string }

export const INSTRUCTIONS_KEY = "bellocode.project-instructions"
/** Limits: per file, all instruction files together, files per folder kind. */
export const LIMITS = { fileBytes: 64 * 1024, instructionBytes: 96 * 1024, filesPerKind: 200 }

export interface FS {
  exists(path: string): boolean
  isDirectory(path: string): boolean
  read(path: string): string | undefined
  list(path: string): string[]
  size(path: string): number
}

export const nodeFS: FS = {
  exists: (path) => existsSync(path),
  isDirectory: (path) => {
    try {
      return statSync(path).isDirectory()
    } catch {
      return false
    }
  },
  read: (path) => {
    try {
      return readFileSync(path, "utf8")
    } catch {
      return undefined
    }
  },
  list: (path) => {
    try {
      return readdirSync(path).sort()
    } catch {
      return []
    }
  },
  size: (path) => {
    try {
      return statSync(path).size
    } catch {
      return 0
    }
  },
}

export function projectConfigOptions(options: any): ProjectConfigOptions | undefined {
  const value = options?.projectConfig
  if (!value || (value.mode !== "bellocode" && value.mode !== "native")) return undefined
  return { mode: value.mode, trustFile: typeof value.trustFile === "string" ? value.trustFile : undefined }
}

/** The trusted project directories (`ProjectTrustFile`); a missing or malformed file trusts nothing. */
export function readTrust(file: string | undefined, fs: FS = nodeFS): string[] {
  if (!file) return []
  try {
    const parsed = JSON.parse(fs.read(file) ?? "")
    return Array.isArray(parsed?.trusted) ? parsed.trusted.filter((item: unknown) => typeof item === "string") : []
  } catch {
    return []
  }
}

function normalise(path: string): string {
  return path.length > 1 && path.endsWith(sep) ? path.slice(0, -1) : path
}

export function isTrusted(directory: string | undefined, trusted: string[]): boolean {
  if (!directory) return false
  const path = normalise(directory)
  return trusted.some((root) => {
    const base = normalise(root)
    return path === base || path.startsWith(base + sep)
  })
}

/** The repository root above `directory` (the nearest folder holding `.git`), or the directory itself. */
export function projectRoot(directory: string, fs: FS = nodeFS): string {
  let current = normalise(directory)
  for (let depth = 0; depth < 64; depth++) {
    if (fs.exists(join(current, ".git"))) return current
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
  return normalise(directory)
}

/** `AGENTS.md` files from the repository root down to `directory` (opencode's own order: outer first). */
export function instructionFiles(directory: string | undefined, fs: FS = nodeFS): { path: string; content: string }[] {
  if (!directory || !fs.isDirectory(directory)) return []
  const root = projectRoot(directory, fs)
  const chain: string[] = []
  let current = normalise(directory)
  for (let depth = 0; depth < 64; depth++) {
    chain.unshift(current)
    if (current === root) break
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
  const files: { path: string; content: string }[] = []
  let total = 0
  for (const folder of chain) {
    const path = join(folder, "AGENTS.md")
    if (!fs.exists(path) || fs.isDirectory(path)) continue
    let content = fs.read(path)
    if (content === undefined) continue
    if (content.length > LIMITS.fileBytes) content = content.slice(0, LIMITS.fileBytes) + "\n[truncated by BelloCode: file too large]"
    if (total + content.length > LIMITS.instructionBytes) break
    total += content.length
    files.push({ path, content })
  }
  return files
}

/** The instruction entry's text (opencode's own wording, so the model reads it the same way), or undefined. */
export function instructionsText(files: { path: string; content: string }[]): string | undefined {
  if (files.length === 0) return undefined
  return files.map((file) => `Instructions from: ${file.path}\n${file.content}`).join("\n\n")
}

// MARK: Markdown with frontmatter

export type Frontmatter = { data: Record<string, string | number | boolean>; body: string }

function scalar(raw: string): string | number | boolean {
  const value = raw.trim()
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) return value.slice(1, -1)
  if (value === "true") return true
  if (value === "false") return false
  if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value)
  return value
}

/** `---` frontmatter with flat `key: value` lines (nested keys are skipped and reported by the caller). */
export function parseFrontmatter(text: string): (Frontmatter & { nested: string[] }) | undefined {
  const normalised = text.replace(/\r\n/g, "\n")
  if (!normalised.startsWith("---\n")) return { data: {}, body: normalised.trim(), nested: [] }
  const end = normalised.indexOf("\n---", 4)
  if (end < 0) return undefined
  const header = normalised.slice(4, end)
  const body = normalised.slice(end + 4).replace(/^[^\n]*\n?/, "").trim()
  const data: Record<string, string | number | boolean> = {}
  const nested: string[] = []
  let parent: string | undefined
  for (const line of header.split("\n")) {
    if (!line.trim() || line.trim().startsWith("#")) continue
    if (/^\s/.test(line)) {
      if (parent && !nested.includes(parent)) nested.push(parent)
      continue
    }
    const match = /^([A-Za-z_][\w-]*)\s*:\s*(.*)$/.exec(line)
    if (!match) return undefined
    parent = match[1]
    if (match[2].trim() === "") continue
    data[match[1]] = scalar(match[2])
  }
  for (const key of nested) delete data[key]
  return { data, body, nested }
}

export type AgentSpec = {
  id: string
  description?: string
  mode?: "primary" | "subagent" | "all"
  system: string
  hidden?: boolean
  color?: string
  steps?: number
  model?: { id: string; providerID: string; variant?: string }
}
export type CommandSpec = { name: string; description?: string; template: string }
export type SkillSpec = { id: string; name: string; description: string; path: string; content: string }
export type Loaded = { trusted: boolean; agents: AgentSpec[]; commands: CommandSpec[]; skills: SkillSpec[]; skipped: string[] }

export const EMPTY: Loaded = { trusted: false, agents: [], commands: [], skills: [], skipped: [] }

function markdownFiles(folder: string, fs: FS, prefix = ""): string[] {
  const out: string[] = []
  for (const name of fs.list(folder)) {
    if (name.startsWith(".")) continue
    const path = join(folder, name)
    if (fs.isDirectory(path)) out.push(...markdownFiles(path, fs, prefix + name + "/"))
    else if (name.endsWith(".md")) out.push(prefix + name)
    if (out.length >= LIMITS.filesPerKind) break
  }
  return out
}

function parseModel(value: unknown): AgentSpec["model"] {
  if (typeof value !== "string" || !value.includes("/")) return undefined
  const [ref, variant] = value.split("#")
  const slash = ref.indexOf("/")
  return { providerID: ref.slice(0, slash), id: ref.slice(slash + 1), ...(variant ? { variant } : {}) }
}

export function agentFromMarkdown(id: string, text: string): AgentSpec | string {
  const parsed = parseFrontmatter(text)
  if (!parsed) return "malformed frontmatter"
  const { data, body, nested } = parsed
  if (nested.length) return `unsupported fields (${nested.join(", ")}): use the global agents folder or native mode`
  const mode = data.mode
  if (mode !== undefined && mode !== "primary" && mode !== "subagent" && mode !== "all") return `unknown mode "${mode}"`
  return {
    id,
    system: body,
    ...(typeof data.description === "string" ? { description: data.description } : {}),
    ...(mode ? { mode } : {}),
    ...(typeof data.hidden === "boolean" ? { hidden: data.hidden } : {}),
    ...(typeof data.color === "string" ? { color: data.color } : {}),
    ...(typeof data.steps === "number" && data.steps > 0 ? { steps: Math.floor(data.steps) } : {}),
    ...(parseModel(data.model) ? { model: parseModel(data.model) } : {}),
  }
}

export function commandFromMarkdown(name: string, text: string): CommandSpec | string {
  const parsed = parseFrontmatter(text)
  if (!parsed) return "malformed frontmatter"
  if (!parsed.body) return "empty template"
  return { name, template: parsed.body, ...(typeof parsed.data.description === "string" ? { description: parsed.data.description } : {}) }
}

export function skillFromMarkdown(path: string, folderName: string, text: string): SkillSpec | string {
  const parsed = parseFrontmatter(text)
  if (!parsed) return "malformed frontmatter"
  const name = typeof parsed.data.name === "string" ? parsed.data.name : folderName
  if (!/^[a-z0-9][a-z0-9-]*$/.test(name)) return `skill name "${name}" must be lowercase letters, digits and hyphens`
  const description = typeof parsed.data.description === "string" ? parsed.data.description : ""
  if (!description) return "missing description"
  return { id: name, name, description, path, content: parsed.body }
}

/** The trusted project's `.opencode/` agents, commands and skills and its `.agents/skills`. */
export function loadProjectConfig(directory: string | undefined, trusted: string[], fs: FS = nodeFS): Loaded {
  if (!directory || !isTrusted(directory, trusted)) return EMPTY
  const root = projectRoot(directory, fs)
  const base = join(root, ".opencode")
  const loaded: Loaded = { trusted: true, agents: [], commands: [], skills: [], skipped: [] }
  const readSmall = (path: string): string | undefined => {
    if (fs.size(path) > LIMITS.fileBytes) {
      loaded.skipped.push(`${relative(root, path)}: larger than ${LIMITS.fileBytes / 1024} KB`)
      return undefined
    }
    return fs.read(path)
  }
  for (const kind of ["agent", "agents"]) {
    const folder = join(base, kind)
    for (const file of markdownFiles(folder, fs)) {
      const text = readSmall(join(folder, file))
      if (text === undefined) continue
      const spec = agentFromMarkdown(file.replace(/\.md$/, ""), text)
      if (typeof spec === "string") loaded.skipped.push(`${relative(root, join(folder, file))}: ${spec}`)
      else loaded.agents.push(spec)
    }
  }
  for (const kind of ["command", "commands"]) {
    const folder = join(base, kind)
    for (const file of markdownFiles(folder, fs)) {
      const text = readSmall(join(folder, file))
      if (text === undefined) continue
      const spec = commandFromMarkdown(file.replace(/\.md$/, ""), text)
      if (typeof spec === "string") loaded.skipped.push(`${relative(root, join(folder, file))}: ${spec}`)
      else loaded.commands.push(spec)
    }
  }
  for (const folder of [join(base, "skill"), join(base, "skills"), join(root, ".agents", "skills")]) {
    for (const name of fs.list(folder)) {
      const path = join(folder, name, "SKILL.md")
      if (!fs.exists(path)) continue
      const text = readSmall(path)
      if (text === undefined) continue
      const spec = skillFromMarkdown(path, name, text)
      if (typeof spec === "string") loaded.skipped.push(`${relative(root, path)}: ${spec}`)
      else if (!loaded.skills.some((skill) => skill.id === spec.id)) loaded.skills.push(spec)
    }
  }
  return loaded
}

/** `$ARGUMENTS` and `$1`…`$n` (the last numbered placeholder takes the rest), as opencode expands them; with no
 * placeholder the arguments are appended. `!`cmd`` shell interpolation is not run (it would need the container). */
export function expandTemplate(template: string, input: string): string {
  const args = (input.match(/"[^"]*"|'[^']*'|[^\s"']+/g) ?? []).map((arg) => arg.replace(/^["']|["']$/g, ""))
  const numbered = template.match(/\$(\d+)/g) ?? []
  const highest = Math.max(0, ...numbered.map((item) => Number(item.slice(1))))
  const expanded = template.replace(/\$ARGUMENTS|\$(\d+)/g, (match, digits) => {
    if (match === "$ARGUMENTS") return input
    const index = Number(digits) - 1
    if (index >= args.length) return ""
    return Number(digits) === highest ? args.slice(index).join(" ") : args[index]
  })
  if (numbered.length === 0 && !template.includes("$ARGUMENTS") && input.trim()) return `${expanded} ${input}`.trim()
  return expanded.trim()
}
