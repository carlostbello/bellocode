// Repository opencode configuration in BelloCode's default mode (docs/features/opencode-config.md).
//
// opencode reads its project-config switch once per server process, and BelloCode's server keeps it off
// (`OPENCODE_DISABLE_PROJECT_CONFIG=1`): a repository's opencode.json and plugins would run inside opencode on the Mac.
// That also drops the repository's AGENTS.md (measured on 2.3.2). This module gives that text back, per session,
// for every project, and, for projects the person trusts, loads the repository's `.opencode/` agents, commands and
// skills (text only; no opencode.json, no plugins). Pure functions over a small file-system interface, so the tests
// run without opencode.

import { closeSync, constants, fstatSync, lstatSync, openSync, readSync, readdirSync, realpathSync } from "fs"
import { dirname, join, relative, sep } from "path"

export type ProjectConfigMode = "bellocode" | "native"
export type ProjectConfigOptions = { mode: ProjectConfigMode; trustFile?: string }

export const INSTRUCTIONS_KEY = "bellocode.project-instructions"
/** Limits: per file, all instruction files together, files per folder kind, folder depth below a kind folder. */
export const LIMITS = { fileBytes: 64 * 1024, instructionBytes: 96 * 1024, filesPerKind: 200, folderDepth: 8 }

/** What `lstat` says a path is (a link is never followed here). */
export type EntryKind = "file" | "directory" | "symlink" | "other"

/**
 * The file-system calls this module makes. Repository content is untrusted: every path is resolved with `realpath` and
 * must stay inside the repository's real root, only regular files are read, and a read is bounded at the descriptor
 * before any byte is decoded (A01/N01 in docs/reviews/v1.0.0-*.md).
 */
export interface FS {
  /** The `lstat` kind, or undefined when the path does not exist or cannot be examined. */
  kind(path: string): EntryKind | undefined
  /** The canonical path with every link resolved, or undefined. */
  realpath(path: string): string | undefined
  list(path: string): string[]
  /**
   * At most `limit` bytes of a regular file, opened without following a final link and without blocking (a FIFO or a
   * device never stalls the server). `size` is the file's full size. Undefined for anything but a regular file.
   */
  readRegular(path: string, limit: number): { text: string; size: number } | undefined
}

const NOFOLLOW = (constants as any).O_NOFOLLOW ?? 0
const NONBLOCK = (constants as any).O_NONBLOCK ?? 0

export const nodeFS: FS = {
  kind: (path) => {
    try {
      const info = lstatSync(path)
      return info.isSymbolicLink() ? "symlink" : info.isDirectory() ? "directory" : info.isFile() ? "file" : "other"
    } catch {
      return undefined
    }
  },
  realpath: (path) => {
    try {
      return realpathSync(path)
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
  readRegular: (path, limit) => {
    let fd: number | undefined
    try {
      fd = openSync(path, constants.O_RDONLY | NOFOLLOW | NONBLOCK)
      const info = fstatSync(fd)
      if (!info.isFile()) return undefined
      const want = Math.max(0, Math.min(info.size, limit))
      const buffer = Buffer.alloc(want)
      let offset = 0
      while (offset < want) {
        const count = readSync(fd, buffer, offset, want - offset, offset)
        if (count <= 0) break
        offset += count
      }
      return { text: buffer.subarray(0, offset).toString("utf8"), size: info.size }
    } catch {
      return undefined
    } finally {
      if (fd !== undefined) {
        try {
          closeSync(fd)
        } catch {}
      }
    }
  },
}

export function projectConfigOptions(options: any): ProjectConfigOptions | undefined {
  const value = options?.projectConfig
  if (!value || (value.mode !== "bellocode" && value.mode !== "native")) return undefined
  return { mode: value.mode, trustFile: typeof value.trustFile === "string" ? value.trustFile : undefined }
}

/** The trust file (`ProjectTrustFile`): trusted project directories and the app's revision of the list. A missing or
 * malformed file trusts nothing. Small and app-written, but still read with a bound. */
export function readTrustFile(file: string | undefined, fs: FS = nodeFS): { trusted: string[]; revision: number } {
  if (!file) return { trusted: [], revision: 0 }
  try {
    const parsed = JSON.parse(fs.readRegular(file, 1024 * 1024)?.text ?? "")
    const trusted = Array.isArray(parsed?.trusted) ? parsed.trusted.filter((item: unknown) => typeof item === "string") : []
    const revision = typeof parsed?.revision === "number" ? parsed.revision : 0
    return { trusted, revision }
  } catch {
    return { trusted: [], revision: 0 }
  }
}

/** The trusted project directories (`ProjectTrustFile`); a missing or malformed file trusts nothing. */
export function readTrust(file: string | undefined, fs: FS = nodeFS): string[] {
  return readTrustFile(file, fs).trusted
}

function normalise(path: string): string {
  return path.length > 1 && path.endsWith(sep) ? path.slice(0, -1) : path
}

/** Whether `path` is `root` or below it (both canonical). */
export function inside(root: string, path: string): boolean {
  const base = normalise(root)
  return path === base || path.startsWith(base === sep ? sep : base + sep)
}

/** Pathname containment only (no repository boundary); see `trustedProject` for the decision the plugin makes. */
export function isTrusted(directory: string | undefined, trusted: string[]): boolean {
  if (!directory) return false
  const path = normalise(directory)
  return trusted.some((root) => inside(root, path))
}

/** The repository root above `directory` (the nearest folder holding `.git`), or the directory itself. */
export function projectRoot(directory: string, fs: FS = nodeFS): string {
  let current = normalise(directory)
  for (let depth = 0; depth < 64; depth++) {
    if (fs.kind(join(current, ".git")) !== undefined) return current
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
  return normalise(directory)
}

/**
 * The trusted repository root for `directory`, or undefined. A trusted folder covers the folders below it only while
 * they belong to the same repository: an independent repository nested inside a trusted checkout (its own `.git`) is
 * a separate project with its own trust (A11). Paths are compared canonically (links resolved) on both sides.
 */
export function trustedProject(directory: string | undefined, trusted: string[], fs: FS = nodeFS): string | undefined {
  if (!directory) return undefined
  const real = fs.realpath(directory)
  if (!real) return undefined
  const root = projectRoot(real, fs)
  for (const entry of trusted) {
    const base = fs.realpath(entry) ?? normalise(entry)
    if (inside(base, real) && projectRoot(base, fs) === root) return root
  }
  return undefined
}

export type BoundedRead = { text: string; size: number } | { refused: string }

/** Reads `path` only if it resolves to a regular file inside `root` (canonical), at most `limit` bytes. */
export function readInside(root: string, path: string, limit: number, fs: FS = nodeFS): BoundedRead {
  const real = fs.realpath(path)
  if (!real) return { refused: "cannot be read" }
  if (!inside(root, real)) return { refused: "links outside the repository" }
  const read = fs.readRegular(real, limit)
  return read ?? { refused: "not a regular file" }
}

/** `AGENTS.md` files from the repository root down to `directory` (opencode's own order: outer first). Each must be a
 * regular file inside the repository; links that leave it, FIFOs and devices are ignored. */
export function instructionFiles(directory: string | undefined, fs: FS = nodeFS): { path: string; content: string }[] {
  if (!directory) return []
  const real = fs.realpath(directory)
  if (!real || fs.kind(real) !== "directory") return []
  const root = projectRoot(real, fs)
  const chain: string[] = []
  let current = real
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
    if (fs.kind(path) === undefined) continue
    const read = readInside(root, path, LIMITS.fileBytes, fs)
    if ("refused" in read) continue
    let content = read.text
    if (read.size > LIMITS.fileBytes) content += "\n[truncated by BelloCode: file too large]"
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

/** Markdown files below `folder` (relative names), following links only while they stay inside `root`, never visiting a
 * folder twice, at most `LIMITS.folderDepth` deep and `LIMITS.filesPerKind` files. Refused links are reported. */
function markdownFiles(root: string, folder: string, fs: FS, skipped: string[]): string[] {
  const out: string[] = []
  const visited = new Set<string>()
  const walk = (path: string, prefix: string, depth: number) => {
    const real = fs.realpath(path)
    if (!real || !inside(root, real) || fs.kind(real) !== "directory" || visited.has(real) || depth > LIMITS.folderDepth) return
    visited.add(real)
    for (const name of fs.list(real)) {
      if (out.length >= LIMITS.filesPerKind) return
      if (name.startsWith(".")) continue
      const child = join(real, name)
      let kind = fs.kind(child)
      if (kind === "symlink") {
        const target = fs.realpath(child)
        if (!target || !inside(root, target)) {
          skipped.push(`${relative(root, join(path, name))}: links outside the repository`)
          continue
        }
        kind = fs.kind(target)
      }
      if (kind === "directory") walk(child, prefix + name + "/", depth + 1)
      else if (kind === "file" && name.endsWith(".md")) out.push(prefix + name)
    }
  }
  walk(folder, "", 0)
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
  const root = trustedProject(directory, trusted, fs)
  if (!root) return EMPTY
  const base = join(root, ".opencode")
  const loaded: Loaded = { trusted: true, agents: [], commands: [], skills: [], skipped: [] }
  const readSmall = (path: string): string | undefined => {
    const read = readInside(root, path, LIMITS.fileBytes, fs)
    if ("refused" in read) {
      loaded.skipped.push(`${relative(root, path)}: ${read.refused}`)
      return undefined
    }
    if (read.size > LIMITS.fileBytes) {
      loaded.skipped.push(`${relative(root, path)}: larger than ${LIMITS.fileBytes / 1024} KB`)
      return undefined
    }
    return read.text
  }
  for (const kind of ["agent", "agents"]) {
    const folder = join(base, kind)
    for (const file of markdownFiles(root, folder, fs, loaded.skipped)) {
      const text = readSmall(join(folder, file))
      if (text === undefined) continue
      const spec = agentFromMarkdown(file.replace(/\.md$/, ""), text)
      if (typeof spec === "string") loaded.skipped.push(`${relative(root, join(folder, file))}: ${spec}`)
      else loaded.agents.push(spec)
    }
  }
  for (const kind of ["command", "commands"]) {
    const folder = join(base, kind)
    for (const file of markdownFiles(root, folder, fs, loaded.skipped)) {
      const text = readSmall(join(folder, file))
      if (text === undefined) continue
      const spec = commandFromMarkdown(file.replace(/\.md$/, ""), text)
      if (typeof spec === "string") loaded.skipped.push(`${relative(root, join(folder, file))}: ${spec}`)
      else loaded.commands.push(spec)
    }
  }
  for (const folder of [join(base, "skill"), join(base, "skills"), join(root, ".agents", "skills")]) {
    const real = fs.realpath(folder)
    if (!real || !inside(root, real) || fs.kind(real) !== "directory") continue
    for (const name of fs.list(real).slice(0, LIMITS.filesPerKind)) {
      const path = join(folder, name, "SKILL.md")
      if (fs.kind(path) === undefined) continue
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
