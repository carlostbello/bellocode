# opencode configuration: global folder, CLI, project trust

How BelloCode keeps its opencode isolated (never `~/.config/opencode` or `~/.local/share/opencode`) while the owner can
still use opencode's own features: the CLI (`opencode auth login` and friends), a global `opencode.json` and
`AGENTS.md`, custom agents, commands, skills and plugins, and repository configuration. Background:
[research 05 §1](../research/05-opencode-integration.md), [containers.md](containers.md),
[execution-modes.md](execution-modes.md).

## What 2.3.2 loads (measured)

Measured on the pinned 2.3.2 binary with a throwaway sandbox (HOME and every XDG directory under a scratch folder),
through the server's own API: `GET /api/agent`, `/api/command`, `/api/skill`, `/api/config` (configuration documents and
directories, lowest to highest priority), `/api/plugin`, plus a local mock OpenAI-compatible provider that recorded the
system prompt of a real turn. Listings fill in a moment after a location activates (poll; the first answer can be empty).

**Global folder** (`$XDG_CONFIG_HOME/opencode/`, for BelloCode `<data>/opencode/config/opencode/`): all of these load,
singular and plural folder names alike.

| Item | Loaded | Evidence |
| --- | --- | --- |
| `opencode.json` (`agents`, `commands`, `instructions`, `policies`, `plugins`, …) | yes | `/api/config` document; its agents listed |
| `AGENTS.md` | yes, into every session's system prompt | marker seen in the recorded system prompt |
| `agents/*.md`, `agent/*.md` | yes | `/api/agent` |
| `commands/*.md`, `command/*.md` | yes | `/api/command` |
| `skills/<name>/SKILL.md`, `skill/<name>/SKILL.md` | yes | `/api/skill` (path under the folder) |
| `plugins/*.ts` | yes (loaded per location) | server log "loading plugin", setup ran |

**Project configuration** (repository `opencode.json`, `.opencode/{agents,commands,skills,plugins}`, `.agents/skills`,
`AGENTS.md` walked up from the working directory to the project root):

| `OPENCODE_DISABLE_PROJECT_CONFIG` | repo `opencode.json`, `.opencode/` | `.agents/skills` | repo `AGENTS.md` | global folder |
| --- | --- | --- | --- | --- |
| unset | loaded | loaded | in the system prompt | loaded |
| `1` (BelloCode until now) | ignored | ignored | **not loaded** (absent from the recorded prompt; file not even watched) | loaded |

- `CLAUDE.md` and `.claude/skills` are off in both cases because BelloCode also sets `OPENCODE_DISABLE_CLAUDE_CODE=1`.
- The flag is read once per server **process** (`config.project` and `InstructionDiscovery.project` are fixed at boot);
  there is no per-location switch.
- An `instructions` entry cannot bring a repository's `AGENTS.md` back while the flag is set: a relative path resolves
  against the global folder when project discovery is off, and an absolute path applies to every project.

**Precedence.** `OPENCODE_CONFIG_CONTENT` (BelloCode's inline layer) is the last, highest-priority document, above the
global folder and above project files. Scalars (`shell`, `formatter`, `lsp`, `experimental.subagent_depth`) set there win
over the user's files; `plugins` lists add up (a user's `"plugins": []` does not remove BelloCode's plugin). One user
setting does win: a `policies` entry `{"action": "plugin.use", "resource": "*", "effect": "deny"}` (in the global
`opencode.json`, or a trusted repository's) disables BelloCode's plugin, and an inline `allow` cannot override it
(policies are deny-wins). The shell stays `bellocode-exec` (inline `shell` and `$SHELL`), but the plugin's container
guard hook, orchestration tools, Auto instrumentation and environment contract would be gone; the Settings ▸ opencode
pane warns when the plugin is not active (see below).

**CLI.** Most subcommands are clients: without flags they connect to the per-user *background service*, discovered
from `$XDG_STATE_HOME/opencode/service.json`, and **start one** (`opencode serve --service`) when none is registered,
which against BelloCode's data would be a second server on the same SQLite database (seen in the sandbox).
`--server <url>` uses a given server, with the password from `OPENCODE_PASSWORD` (environment only; a wrong one gives
"rejected the password"); `--standalone` starts a private stdio server. Commands without these flags (`mcp add`,
`plugin add|remove`, `debug paths`) only edit files. There is no `agent create` in 2.3.2. Server-side reload exists:
`POST /api/location/reload` rebuilds every loaded location (pending permissions and forms are cancelled; running
sessions continue at the next step boundary).

**Plugin context.** A plugin's per-location context has `skill.transform` (`add(info, files)`), `agent.transform`
(`update(id, edit)` on a default agent; there is no `add`), `command.transform` (`add({name, description, execute})`)
and `session.instructions.entry.put`. A transform that throws disables the whole plugin ("disabled plugin after
transform failure"), so BelloCode's plugin only uses editor methods verified on the binary.
