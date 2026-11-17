// Container execution (docs/features/containers.md): pure helpers for the guard and the agent's guidance. The app
// writes the helper's configuration file; the plugin only reads it (no secrets in it).

export type ContainerOptions = { readonly helper: string; readonly config: string }

export type Inventory = { readonly os?: string; readonly arch?: string; readonly tools?: readonly string[] }
export type Workspace = {
  readonly roots: readonly string[]
  readonly container: string
  readonly image?: string
  readonly inventory?: Inventory
  readonly blocked?: { readonly message: string; readonly fix?: string }
}
export type ExecConfig = {
  readonly workspaces: readonly Workspace[]
  readonly runtimeBlocked?: { readonly message: string; readonly fix?: string }
}

export const CONTAINER_GUIDANCE_KEY = "bellocode.container"

export function containerOptions(options: unknown): ContainerOptions | undefined {
  const value = (options as { container?: { helper?: unknown; config?: unknown } } | undefined)?.container
  if (!value || typeof value.helper !== "string" || typeof value.config !== "string") return undefined
  if (!value.helper.startsWith("/") || !value.config.startsWith("/")) return undefined
  return { helper: value.helper, config: value.config }
}

function inside(path: string, root: string): boolean {
  return path === root || path.startsWith(root.endsWith("/") ? root : root + "/")
}

/** The workspace whose longest root contains `directory`. */
export function workspaceFor(config: ExecConfig, directory: string | undefined): Workspace | undefined {
  if (!directory) return undefined
  let best: Workspace | undefined
  let length = -1
  for (const workspace of config.workspaces ?? []) {
    for (const root of workspace.roots ?? []) {
      if (inside(directory, root) && root.length > length) {
        best = workspace
        length = root.length
      }
    }
  }
  return best
}

/** The session instruction telling the model where its commands run. */
export function containerGuidance(config: ExecConfig | undefined, directory: string | undefined): string {
  const workspace = config ? workspaceFor(config, directory) : undefined
  const lines = [
    "Commands you run (the shell tool, terminals, command templates) execute in a Linux container managed by BelloCode, never on the user's Mac.",
  ]
  if (workspace) {
    const inventory = workspace.inventory
    const what = [workspace.image ? `image ${workspace.image}` : undefined, inventory?.os, inventory?.arch].filter(Boolean).join(", ")
    if (what) lines.push(`- Container: ${what}.`)
    lines.push(`- The project is mounted at the same path as on the Mac (${workspace.roots[0]}); your file tools edit those files directly and the container sees edits at once.`)
    if (inventory?.tools?.length) lines.push(`- Available in the container: ${inventory.tools.join(", ")}. Install other tools inside the container (they are lost when it is rebuilt).`)
  } else {
    lines.push("- This directory is not inside a project with a container environment, so commands here are refused.")
  }
  lines.push(
    "- Host tools (Homebrew, the Mac's python, node, bun, npm, docker) are not available and must not be used.",
    "- Dev servers: listen on 127.0.0.1 or 0.0.0.0 inside the container; no ports are published. The user opens them from BelloCode's Ports list or built-in browser.",
    "- There is no Docker access inside the container.",
    '- A command that fails with "BelloCode: … The command was not run." did not run: tell the user the fix it names instead of retrying.',
  )
  const blocked = config?.runtimeBlocked ?? workspace?.blocked
  if (blocked) lines.push(`Right now commands cannot run: ${blocked.message}`)
  return lines.join("\n")
}
