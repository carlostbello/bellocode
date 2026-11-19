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

## Design

### Global folder and Settings ▸ opencode

Window ▸ opencode… (or Settings ▸ opencode): the folder path (`OpenCodeDirectories.globalConfigFolder`), **Open
opencode.json** and **Open AGENTS.md** (created from `GlobalConfigFolder` templates when missing; an existing file is never
rewritten), **Reveal in Finder**, and the agents, commands, skills and plugins folders (created on first open). Because
opencode drops a malformed `opencode.json` silently, the pane checks it itself (JSONC: comments and trailing commas
allowed) and shows the line, column and message, or says opencode ignored the file when `GET /api/config` does not list
it. No crash loop: the server keeps running without that document. Below that, the agents, commands and skills the
server reports for the selected project, each with a glyph-and-word source badge: **Global** (file in the folder or an
`opencode.json` entry), **Project** (repository), **Plugin** (anything else, e.g. a global plugin). Built-in items are not
listed. Also shown: global plugins (they run inside opencode on the Mac), files a trusted project's loader skipped and
why, and a warning when BelloCode's plugin is not active. **Reload Configuration** (also Window ▸ Reload opencode
Configuration) is `POST /api/location/reload` and asks first only when approvals or questions would be cancelled;
**Restart Server…** (`ServerSupervisor.restart`; the event stream reconnects and resyncs) asks first when threads would be
interrupted. Opening a file, reloading and trusting give feedback in place; failures are shown in the pane, the previous
list stays visible as stale while offline.

### Repository configuration and trust (one server, many projects)

opencode reads its project-config switch once per process, and one BelloCode server serves every project. Turning the
switch on for one trusted project would load every other project's `opencode.json` and plugins too. So trust works in
two layers:

1. **Default (`RepositoryConfigPolicy.bellocode`).** The server keeps `OPENCODE_DISABLE_PROJECT_CONFIG=1` (now owned by
   `ServerConfiguration.repositoryConfig`, no longer hard-coded in `ContainerExecution`). BelloCode's plugin
   (`Plugin/src/project.ts`):
   - **Every project, trusted or not:** writes the repository's `AGENTS.md` chain (repository root down to the
     session's folder, outer first; 64 KB per file, 96 KB total) as the session instruction entry
     `bellocode.project-instructions`, in opencode's own wording. It is written in the awaited session `prompt` hook
     (`SessionPrompt.prepare`), so the first turn already has it, and refreshed at each run when the files change. It is
     text, not code. `CLAUDE.md` stays off, as before.
   - **Trusted projects only** ("Trust this project's opencode config", per project, default off): the repository's
     `.opencode/agent(s)/*.md`, `.opencode/command(s)/*.md`, `.opencode/skill(s)/*/SKILL.md` and `.agents/skills` are
     added to that project's location through the per-location transforms. Agents support `description`, `mode`,
     `model` (`provider/model#variant`), `hidden`, `color` and `steps`; nested frontmatter such as `permission` or
     `tools` is skipped and reported. Commands expand `$ARGUMENTS` and `$1…$n`; `!`cmd`` shell interpolation is not run.
     The repository's `opencode.json` and plugins never load in this mode, trusted or not.
   - Trust is stored in `app_opencode_trust` (migration `v14-opencode-trust`), mirrored to `<data>/bellocode-trust.json`
     for the plugin, and applied by RPC `bellocode.projectConfig`, which re-reads the file and replays the transforms.
     It applies at once with no restart, and untrusting removes the items again (verified). Offline, the choice is
     saved and applied at the next location setup ("Saved; applied when opencode is back").
2. **"Load every repository's opencode.json and plugins" (`.native`, server-wide, off by default).** opencode loads every
   repository's configuration and plugins itself, for **every** project the server opens, trusted or not. The confirmation
   says so, and says that repository plugins are code running inside opencode on the Mac, outside the container. It is
   read at each launch (`repositoryConfigProvider`), so the change restarts the server. In this mode the plugin does
   nothing for repository configuration (no double AGENTS.md).

This is a limit of opencode 2.3.2, stated honestly: per-project trust covers text configuration only.
Per-project plugins and `opencode.json` would need a separate server process per trust level (a second writer on the
database, or separate sessions).

### Precedence and what the user cannot override

`OPENCODE_CONFIG_CONTENT` is the highest-priority layer (measured above), so `shell` (`bellocode-exec`), `formatter`
and `lsp` off, `subagent_depth`, BelloCode's MCP overrides and its plugin entry win over the global `opencode.json` and
over native project config. `plugins` add up, so a user's list cannot remove BelloCode's. The one exception is a
`plugin.use` deny policy, which opencode applies deny-wins, and BelloCode cannot block it through configuration. The pane
detects it (`GET /api/plugin`: `bellocode` not active, plus the denying document's `policies`) and shows "BelloCode's plugin
is off" with the reason. The shell stays `bellocode-exec` through the inline `shell` and `$SHELL`, but the guard hook,
orchestration tools and environment contract are gone until the policy is removed.

### Command-line tool

`bellocode-opencode` (Contents/Helpers, a small Swift executable sharing `OpenCodeDirectories`) runs the bundled opencode
with BelloCode's isolated HOME and XDG directories (redirecting variables such as `OPENCODE_CONFIG_DIR` and
`OPENCODE_DB` removed; project config off for any private server). Routing is decided by `OpenCodeCLI.plan`:

| Situation | What happens |
| --- | --- |
| BelloCode running | Client commands (`auth …`, `models`, `run`, `mcp list`, `session …`, the interactive interface…) get `--server <url>`; the per-launch password goes in `OPENCODE_PASSWORD` (never argv). Credential writes go through the running server, the database's one writer (2.3.2 has no `auth import --server`; every client command takes `--server`). |
| BelloCode not running | Account, model, session, plugin-list and debug commands get `--standalone`. `run`, the interactive interface, `api`, `mcp list`, `reload` are refused: without BelloCode's server there is no container shell, so they would run on the Mac. |
| Always | `service`, `serve`, `upgrade`, `uninstall`, `pair`, `acp` refused; `--standalone` refused while BelloCode runs; an explicit `--server` never receives BelloCode's password; `mcp add`, `plugin add/remove`, `debug paths`, help run directly. |

The server's address and password are in `<data>/run/server.json`, written by the supervisor when the server is verified
and removed when it exits. The file is created 0600 (atomic, O_EXCL) in a 0700 folder; readers refuse group or other access,
another owner or a dead pid. **Install Command Line Tool…** (BelloCode menu and the pane) links the helper into
`~/.local/bin` (or a writable `/usr/local/bin`) after confirming. It is idempotent, repairs a link to another BelloCode
copy, never replaces or removes a file or foreign link, and Uninstall removes only BelloCode's links. **Terminals:**
BelloCode's terminals run in Linux workspace containers, where a macOS binary cannot run. Putting the server's password
inside the agent's container would also give the agent control of the server, so the tool is not offered there; use
Terminal on the Mac. (In development runs without containers, the server's PATH already starts with Contents/Helpers.)

## Verification

- Unit: `OpenCodeConfigTests` (wrapper environment and routing, connection file modes and staleness, trust file, templates,
  JSONC positions, policy in the server environment), `OpenCodeTrustTests` (migration from v13, round trip across reopen and
  `rebuild()`, trust file mirroring, offline pending, broken `opencode.json`), `OpenCodeSettingsTests` (installer idempotent and
  never touching foreign files, stored policy, menu items), plugin `project.test.ts` (AGENTS.md chain and limits, frontmatter,
  agents/commands/skills, template expansion, trust containment; `make plugin-test`: 62 pass).
- Real binary (`BELLOCODE_CONFIG_REAL=1 swift test --filter OpenCodeConfigRealBinary`, local mock provider, no network):
  a custom agent and skill in the isolated global folder are listed as Global; an untrusted repository's `.opencode`
  items and its `opencode.json` agent do not load; trusting loads them as Project with the same server pid, and
  untrusting removes them; the connection file names the server and is gone after stop; the repository `AGENTS.md` marker
  is in the system prompt of an untrusted project's turn, and the session has the `bellocode.project-instructions` entry.
- Wrapper end to end: built bundle, through a symlink, against a sandbox server: `auth list`, `debug agents`, `models`,
  `mcp list` through `--server`; `service start` and `--standalone` refused while running; an insecure connection file
  refused; with no server `run` refused and `auth list` on a private server; no background service ever started.
- Snapshots: `--snapshot opencode` writes `opencode-{untrusted,trusted,problems,window}-{light,dark}.png` (checked light
  and dark; copies in `docs/snapshots/opencode-*.png`).

## UX checklist (03-ux-patterns.md §E)

Purpose and context: every action names its scope (global folder path, the selected project, "for every project");
trust and the server-wide switch say what runs where. States: first use (files created from templates), normal, empty
("None besides opencode's built-in ones"), loading, stale/offline (list kept, "Stale: …"), failure (malformed
`opencode.json` with position, plugin off, attached server without a folder), success messages. Keyboard: every action is
a menu item (BelloCode ▸ Install/Uninstall Command Line Tool…, Window ▸ opencode…, Reload opencode Configuration) and a
standard button, toggle or select in the pane. Reversible: trust applies at once and is undone by switching it back;
confirmations only where work is interrupted (restart, reload with pending approvals, native mode). Accessibility: badges
are glyph + word, rows labelled with name and source. Not exercised: VoiceOver walk-through, a person at the screen,
two windows, 30 sessions.

## Follow-ups

- Per-project plugins and `opencode.json` need opencode support for per-location project config (or a second server
  per trust level); revisit on upgrades.
- A standalone CLI server and a BelloCode launch in the same moment would be two writers; the app could take a lock
  that the wrapper holds while a private server runs.
- `!`cmd`` interpolation in trusted project commands could run through `bellocode-exec` in the project's container.
- `opencode.json` schema-level problems (an entry opencode drops) are only in opencode's log ("configuration normalization
  diagnostic"); surfacing them needs a log reader.
