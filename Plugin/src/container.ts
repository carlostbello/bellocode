// Container execution (docs/features/containers.md): pure helpers for the guard and the agent's guidance. The app
// writes the helper's configuration file; the plugin only reads it (no secrets in it).

export type ContainerOptions = { readonly helper: string; readonly config: string }

export type Inventory = { readonly os?: string; readonly arch?: string; readonly tools?: readonly string[] }
export type Mode = "shared" | "project" | "host-docker"
export type Workspace = {
  readonly roots: readonly string[]
  readonly container: string
  readonly user?: string
  readonly image?: string
  readonly inventory?: Inventory
  readonly blocked?: { readonly message: string; readonly fix?: string }
  readonly mode?: Mode
  readonly docker?: { readonly host: string; readonly binary?: string }
  /** The workspace's creation settings; `egress` is set when BelloCode's egress proxy is enforced (secret manager). */
  readonly spec?: { readonly egress?: { readonly network?: string } }
}
export type ExecConfig = {
  readonly workspaces: readonly Workspace[]
  readonly runtimeBlocked?: { readonly message: string; readonly fix?: string }
  readonly trustedRoots?: readonly string[]
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

/** The environment contract (docs/features/containers.md, "Environment contract"): the session instruction telling
 * the model precisely where its commands run, filled from the helper configuration the app keeps current. No secrets
 * are in that file, so none can reach the instruction. */
export function containerGuidance(config: ExecConfig | undefined, directory: string | undefined): string {
  const workspace = config ? workspaceFor(config, directory) : undefined
  const mode: Mode = workspace?.mode ?? "project"
  const lines: string[] = []
  if (!workspace) {
    lines.push(
      "Commands you run (the shell tool, terminals, command templates) execute in a Linux container managed by BelloCode, never on the user's Mac.",
      "- This directory is not inside a project with a container environment or inside the code roots, so commands here are refused.",
    )
  } else if (mode === "host-docker") {
    lines.push(
      "This project runs in BelloCode's \"Host shell, docker only\" mode: your shell commands run on the user's Mac, but only ONE plain `docker`, `docker compose` or `docker buildx` command per call is allowed. Anything else (other programs, pipes, `&&`, `;`, redirection, `$(…)`, variables, globs) is refused, not interpreted.",
      `- Working directory: ${directory ?? workspace.roots[0]}. Only the project (${workspace.roots.join(", ")}) can be bind-mounted.`,
      "- Run everything else inside a container, for example `docker compose run --rm app npm test` or `docker run --rm -v \"$PWD\":/w -w /w node:22 npm ci` (use the absolute project path instead of $PWD: variables are refused).",
      "- There is no terminal in this mode.",
    )
  } else {
    const inventory = workspace.inventory
    const what = [workspace.image ? `image ${workspace.image}` : undefined, inventory?.os, inventory?.arch ? `${inventory.arch} Linux` : undefined]
      .filter(Boolean)
      .join(", ")
    if (mode === "shared") {
      lines.push(
        "Commands you run (the shell tool, terminals, command templates, MCP servers) execute in BelloCode's shared Linux workspace container, never on the user's Mac.",
        `- Code roots mounted read-write at the same absolute paths as on the Mac: ${(config?.trustedRoots ?? workspace.roots).join(", ")}. Every repository under them is visible, so you can read, build and test other repositories there (multi-repo work) without asking; paths outside them are not mounted and need the user's approval.`,
        `- Your working directory is the thread's project (${directory ?? workspace.roots[0]}); other projects share this container, so do not stop or reconfigure it and keep per-project state inside each project.`,
      )
    } else {
      lines.push(
        "Commands you run (the shell tool, terminals, command templates, MCP servers) execute in this project's own Linux container managed by BelloCode, never on the user's Mac.",
        `- Mounted at the same absolute paths as on the Mac: ${workspace.roots.join(", ")} (the project and its worktrees). Nothing else from the Mac is visible.`,
      )
    }
    if (what) lines.push(`- Container: ${what}${workspace.user ? `, user ${workspace.user} (the Mac user's uid:gid, so files you create belong to them)` : ""}. $HOME is /home/bellocode (kept across restarts).`)
    if (inventory?.tools?.length) lines.push(`- Available tools: ${inventory.tools.join(", ")}. Install other tools in the container or use a version manager such as mise (they are lost when the container is rebuilt).`)
    lines.push(
      "- Your file tools (read, edit, write) work on the Mac directly; the container sees the same files at once. Commands run on Linux, not macOS.",
      "- Linux build outputs and dependency folders (node_modules, .venv, target, native modules) are for the container: do not expect the Mac's tools to use them, and do not install dependencies on the Mac.",
      workspace.docker
        ? "- `docker`, `docker compose` and `docker build` work inside the container: they talk to BelloCode's filtered Docker endpoint (DOCKER_HOST is set for you; do not change it or look for a Docker socket). It allows containers, networks and volumes you create, bind mounts only inside " +
            (mode === "shared" ? "the code roots" : "the project") +
            ", images allowed by the image policy, and the classic builder (BuildKit/buildx is not available). Privileged mode, added capabilities, devices, host networking/PID/IPC and anything BelloCode or other projects own are refused with \"BelloCode refused this Docker request: …\": change the request as the message says instead of retrying."
        : "- Docker is not available inside the container right now.",
      "- localhost differs on each side: a server you start listens in the container (bind 0.0.0.0 or 127.0.0.1 there); the user opens it through BelloCode's Ports list or built-in browser, which forwards it to 127.0.0.1 on the Mac. Ports you publish with docker are bound to 127.0.0.1 on the Mac. Compose services reach each other by service name.",
    )
  }
  lines.push(
    "- Git: BelloCode's git actions (stage, commit, push, merge requests) run on the Mac with repository hooks disabled. The container's git has no credentials: use BelloCode's git and push tools for anything that needs the remote, and run checks such as linters or tests explicitly in the container (hooks do not run for you).",
    "- The network may intercept TLS with the company's certificate authority: keep certificate verification on (never use --insecure, NODE_TLS_REJECT_UNAUTHORIZED=0 or similar); if a download fails on certificates, report it.",
    "- Never fall back to running anything on the Mac (no Homebrew, host python, node, bun or npm). If a mount, port, tool, permission or certificate is missing, report the precise blocker instead of guessing.",
    ...(workspace?.spec?.egress
      ? [
          "- Network: HTTP and HTTPS go only through BelloCode's proxy (HTTPS_PROXY is set; its CA is trusted). Direct connections, raw TCP, UDP, IPv6 and DNS for outside names do not work; use tools that honour HTTPS_PROXY (curl, npm, pip, git). A 403 or 502 whose body starts with \"BelloCode\" comes from the proxy and names the rule.",
        ]
      : []),
    '- A command that fails with "BelloCode: … The command was not run." did not run: tell the user the fix it names instead of retrying.',
  )
  const blocked = config?.runtimeBlocked ?? workspace?.blocked
  if (blocked) lines.push(`Right now commands cannot run: ${blocked.message}`)
  return lines.join("\n")
}
