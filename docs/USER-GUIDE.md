# BelloCode user guide

How to set up and use BelloCode day to day. For how each area is built and what was tested, follow the links to the
[feature notes](features/). Menu paths are written as **Menu ▸ Item**; Settings opens with ⌘,.

- [1. Before you start](#1-before-you-start)
- [2. First launch](#2-first-launch)
- [3. Projects and threads](#3-projects-and-threads)
- [4. The composer](#4-the-composer)
- [5. Models](#5-models)
- [6. opencode configuration: AGENTS.md, agents, skills](#6-opencode-configuration-agentsmd-agents-skills)
- [7. Permission modes, Auto and approvals](#7-permission-modes-auto-and-approvals)
- [8. Where commands run: containers](#8-where-commands-run-containers)
- [9. Secrets](#9-secrets)
- [10. Browsers: built-in and shared Chrome](#10-browsers-built-in-and-shared-chrome)
- [11. Changes, git and worktrees](#11-changes-git-and-worktrees)
- [12. GitLab](#12-gitlab)
- [13. Agents working with agents](#13-agents-working-with-agents)
- [14. Scheduled tasks](#14-scheduled-tasks)
- [15. Terminal](#15-terminal)
- [16. Keyboard shortcuts](#16-keyboard-shortcuts)
- [17. Troubleshooting](#17-troubleshooting)

## 1. Before you start

- An Apple Silicon Mac on macOS 15 or later.
- [Rancher Desktop](https://rancherdesktop.io), set to the **dockerd (moby)** container engine (Rancher Desktop ▸
  Preferences ▸ Container Engine). BelloCode runs every command, terminal and the shared Chrome in containers; without
  Rancher Desktop the agent can still read and edit files and chat, but commands are refused, never run on the Mac.
- A container image for your workspace. BelloCode ships none: use your organisation's development image, or build one.
  [features/workspace-image.Dockerfile](features/workspace-image.Dockerfile) is an example based on
  `node:22-bookworm-slim` with the Docker CLI and Compose added.
- Optional: a paid model provider account, and a GitLab personal access token.

To install a release build, see [README.md](../README.md#install-a-release-build). BelloCode is ad-hoc signed and not
notarised, so the first open needs **Open Anyway** or removing the quarantine flag.

## 2. First launch

1. **Welcome.** The welcome screen says whether free models are available. Choose **Connect a provider**,
   **Import from opencode** (copies accounts from an opencode install you already have) or **Skip**. You can do either
   later in Settings ▸ Accounts or with BelloCode ▸ Connect Provider…; Help ▸ Welcome to BelloCode… shows the screen
   again.
2. **Containers.** Open Settings ▸ Containers:
   - **Runtime** shows whether Rancher Desktop is installed, running and on the right engine, with a button for the fix
     (Check Again re-tests).
   - **Execution** sets the default execution mode for projects (section 8). The default is the shared workspace.
   - **Code roots** are the folders your repositories live in, for example `~/Documents/Repos`. The first run suggests
     one. A root may not be your home folder, a system folder or a credential folder, and Rancher Desktop must share it
     with its VM (the row says how when it does not).
   - **Default image** is the image projects use unless they choose their own.
   - **Registry sign-in** stores a registry password or token in your Keychain if your image needs one.
3. **Add a project:** File ▸ Add Project… (⇧⌘O) and pick a repository folder. For the shared workspace it must be inside a
   code root.
4. **Start a thread:** File ▸ New Thread (⌘N), type a request and press Return.

BelloCode keeps its own opencode data in `~/Library/Application Support/BelloCode/opencode/` and never reads or writes
your own `~/.config/opencode` or `~/.local/share/opencode`. Closing the last window does not quit: agents and schedules
keep running, and the Dock icon reopens the window. The menu bar item (Settings ▸ Notifications) shows what needs you.

## 3. Projects and threads

- **Sidebar.** Threads grouped by project (View ▸ Group Threads by Project) or by state across projects (View ▸ Show
  All Threads by State). **Needs you** at the top lists threads blocked on an approval or question, or finished and
  unread; Go ▸ Next Needs Attention (⌥⌘A) cycles through them. Filter with ⌥⌘F; search all messages with ⇧⌘F.
- **Thread actions** (Thread menu or right-click): Rename, Pin (⇧⌘P), Mark as Unread (⇧⌘U), Settle (⇧⌘S, file it as
  done), Snooze until later today, tomorrow, next week or a time (⌥⌘S), Archive (⌘⌫) and Delete (⌥⌘⌫). Archive and
  Delete apply at once and offer Undo; File ▸ Reopen Closed Thread (⇧⌘T) brings a closed one back.
- **Projects** (File menu): Pin Project, Move Project Up/Down, Archive Project, Reveal in Finder (⌥⌘R), Open in
  Terminal, Copy Path (⌃⇧⌘C).
- **Navigation:** Command Palette (⌘K) runs any command, Quick Open (⌘P) jumps to threads and files, Go ▸ Back/Forward
  (⌘[ / ⌘]). File ▸ New Window (⇧⌘N) opens another window with its own selection.
- **Right panel** (View ▸ Show Right Panel, ⌥⌘I) has tabs **Changes**, **Browser**, **Terminal**, **Agents**,
  **Merge Requests**, **Auto** and **Chrome**. There is no file browser tab; open files with ⌘P or the palette.
- **Transcript:** Edit ▸ Find ▸ Find in Thread… (⌘F), View ▸ Jump to Latest (⇧⌘J), Previous/Next Prompt (⌥⌘↑ / ⌥⌘↓),
  Go to Last Failure (⌥⌘L). Edit ▸ Copy Message, Copy as Markdown (⌥⇧⌘C) and Copy Code act on the selected message.

The header of every thread shows its project, folder, branch and worktree, so you can always tell where it acts.

## 4. The composer

- **Send:** Return sends and Shift-Return adds a line (Settings ▸ General can make ⌘Return the send key instead). `@`
  mentions files, `/` runs opencode commands, and you can paste or drop images and files as attachments. A large paste
  becomes an attachment; Edit ▸ Paste Inline (⌥⌘V) keeps it as text.
- **While the agent works**, a new message is either **queued** (delivered after the current turn, the default for
  Return) or used to **steer** (delivered at the agent's next step, ⌘Return). The hint under the composer says which
  key does what, and queued messages show above the composer with Steer Now and Remove. Thread ▸ Queue After This Turn
  and Steer at Next Step do the same from the menu.
- **Stop** (⌘.) interrupts the run. A message is shown as sent only after the server accepts it; if that is not
  confirmed, Thread ▸ Retry Unconfirmed Message sends it again.
- **Drafts** are saved as you type, per thread and per project, and restored after a relaunch. If a draft (for example
  an attachment) could not be saved when you quit, BelloCode asks before quitting (Try Again or Quit Anyway). If the
  first send from a new-thread draft fails, the text comes back in the new thread's composer.
- **Plan mode** (⌥⌘P) switches the thread to opencode's read-only plan agent and back to build.

## 5. Models

- **Per thread:** the model button in the composer (⇧⌘M, Thread ▸ Choose Model…) lists the models of every connected
  provider with Free / price, context size and reasoning effort (⇥).
- **Background tasks:** Settings ▸ Models (Window ▸ Models…, ⌃⌥⌘M) chooses the default model for new threads, the small
  model for thread titles, the Auto reviewer, the model that writes commit messages and merge requests, and the model
  for delegated threads and scheduled tasks. Saving the first two reloads opencode, which cancels pending approvals,
  so the pane asks first (Reload Now or Save Only).
- **Providers:** Settings ▸ Accounts or BelloCode ▸ Connect Provider… (API key or sign-in in the browser). From
  Terminal on your Mac, the bundled CLI does the same through the running app:

  ```sh
  bellocode-opencode auth login
  bellocode-opencode models
  ```

  Install it with BelloCode ▸ Install Command Line Tool… (a link in `~/.local/bin`, or `/usr/local/bin` if writable).
  It always uses BelloCode's isolated data. With the app running it talks to the app's server; without it, commands
  that would run code on the Mac (`run`, the interactive interface) are refused. It is not available inside BelloCode's
  own terminals, which run in Linux containers.

opencode's free models have a usage allowance. When it runs out, threads and Auto's reviewer fail with "usage limit";
see [Troubleshooting](#17-troubleshooting). Details: [features/models.md](features/models.md).

## 6. opencode configuration: AGENTS.md, agents, skills

BelloCode's opencode reads a global configuration folder:

```
~/Library/Application Support/BelloCode/opencode/config/opencode/
  opencode.json        # opencode settings (JSONC: comments and trailing commas are fine)
  AGENTS.md            # instructions added to every session
  agents/  commands/  skills/<name>/SKILL.md  plugins/
```

Window ▸ opencode… (Settings ▸ opencode) opens these files and folders (creating them from templates when missing),
checks `opencode.json` for syntax errors with line and column, and lists the agents, commands and skills the server
loaded with their source (Global, Project or Plugin). After editing, use **Reload Configuration** (Window ▸ Reload
opencode Configuration); it asks first if pending approvals would be cancelled. **Restart Server…** restarts opencode.

**Repository configuration.** Every project's `AGENTS.md` files are used. A repository's `.opencode/` agents, commands
and skills are used only when you turn on **Trust this project's opencode config** for that project in the same pane
(off by default). A repository's own `opencode.json` and plugins are not loaded unless you change the repository config
policy there, which applies to every project at once; the pane explains the trade-off. Do not add a policy that denies
`plugin.use` for `*`: it disables BelloCode's own plugin (the pane warns when the plugin is not active). Details:
[features/opencode-config.md](features/opencode-config.md).

## 7. Permission modes, Auto and approvals

Each thread has a permission mode: the composer's mode control (⇧⌘A) or Thread ▸ Set Permission Mode.

| Mode | Shortcut | What happens |
| --- | --- | --- |
| Ask Every Time | ⌃⌥⌘1 | Edits, commands and access outside the project ask you |
| Auto-Accept Edits | ⌃⌥⌘2 | Edits are allowed; commands and outside access ask |
| Auto | ⌃⌥⌘3 | BelloCode's risk policy approves routine work and asks you about risky actions |
| Full Access | ⌃⌥⌘4 | Everything is allowed; risky actions are flagged as notices afterwards |

New threads start in **Full Access**. Change it per draft or thread.

**Approvals and questions** appear above the composer and are counted in the sidebar, including those from child
agents. Allow Once (⌥⌘Y), Always Allow (⇧⌥⌘Y, saved for the project), Deny or Dismiss (⌥⌘N, optionally with a note),
Submit Answer (⌥⌘↩), and Previous/Next Request (⌥⌘[ / ⌥⌘]).

**Auto** never lets a model override its rules. It refuses access to BelloCode's and opencode's own data, the Keychain
and the Docker socket. It always asks you about secret-looking files and credential folders, environment dumps,
searches over hidden or ignored files, recursive searches whose tree contains a secret-looking file (policy
`bellocode-auto-5` follows every folder grep would enter, including `.git` and `node_modules`, reads options in every
spelling grep accepts, abbreviations included, and asks when the shell would change the words grep receives, such as a
brace expansion), paths outside the
project and code roots, other projects, agent and MCP configuration, credential-bearing network requests, destructive
git, irreversible deletes, publishing and deploying, package installs and commands it cannot analyse. Reads,
searches, read-only commands and ordinary edits inside the project and your code roots are allowed, and so is anything
a saved "Always" grant covers (never the mandatory cases above). Everything else goes to a reviewer model (Settings ▸
Models ▸ Auto reviewer), which sees the action but never your files or history; when it is unsure or fails, you decide.
The **Auto** tab (Thread ▸ Show Auto Audit Log, ⌃⌘J) lists every decision and its reason. In Full Access, Thread ▸ Mark Risk Notices Reviewed clears the notices.

**Interrupts.** Agents may stop other threads. A stopped thread shows who stopped it, and its queued work is held until
you choose Thread ▸ Resume Interrupted Thread (⌃⌥⌘P); a message another agent sends to a held thread waits too. MCP
servers always need your approval. Details: [features/auto-mode.md](features/auto-mode.md),
[features/agent-ui.md](features/agent-ui.md).

## 8. Where commands run: containers

opencode, its file tools and BelloCode's git run on the Mac and edit your files in place. Everything that is *run* (the
agent's shell commands, terminals, MCP servers, dev servers) runs in a container. Choose per project in Window ▸
Project Environment… (Settings ▸ Environment); the header, context line and terminal show the current mode.

| Mode | Use it when |
| --- | --- |
| **Shared workspace** (default) | One container for you, mounting every code root at the same path. The agent can work across repositories in your roots without extra approvals. Projects outside the roots are blocked until you add the root. |
| **Project container** | The project needs its own image, services or caches, or has a `.devcontainer/devcontainer.json` (opt in; BelloCode builds it locally, refuses root users and asks before running lifecycle commands). |
| **Host shell, docker only** | Weaker isolation: one plain `docker …` command per call, run with Rancher Desktop's CLI under a sandbox. No terminals. |

Commands inside a container run as your numeric user, never root and never by name; BelloCode verifies the image's
user before anything starts, and recreates an older workspace once when it does not meet that. Inside the
workspace, `docker` and `docker compose` work through a filtered endpoint that only lets a project manage its own
containers, images and volumes; refused requests are listed in the pane with the reason.

Other container settings: services (a `compose.yaml` or services defined in the pane), package caches, ports
forwarded to the Mac, file-change forwarding for watchers, the image policy (allowed registries, digests), the company
CA and proxy, and network diagnostics. **MCP servers** (Window ▸ MCP Servers…) run in containers too; global ones
apply to every project that opts in. Window ▸ Verify Container Isolation checks the boundary; Window ▸ Prune BelloCode
Resources… lists BelloCode's stopped containers, unused volumes and networks and the images it pulled, and removes them
after one confirmation; nothing without BelloCode's labels is touched. Details:
[features/containers.md](features/containers.md), [features/execution-modes.md](features/execution-modes.md).

## 9. Secrets

Settings ▸ Secrets (Window ▸ Secrets…) keeps tokens and keys in your Keychain. Add one with **Add Secret…**, or approve
an agent's request card. Each secret has a scope (this project, your code roots or all projects), destinations it may
be sent to, and a mode:

| Mode | The agent gets | What BelloCode promises |
| --- | --- | --- |
| **Brokered** | A handle (`{{secret:NAME}}`) for BelloCode's HTTP request tool; BelloCode makes the request | The agent cannot see this value |
| **Placeholder** | `$NAME` holding a random placeholder in its commands; an egress proxy swaps in the real value only for the bound destinations | The agent cannot see this value |
| **Visible** | The value itself in `$NAME`, after you confirm once | The agent can see this value |

Values shorter than 8 characters can only be Visible (too short to detect if a service echoes them). Rotate replaces the
value and keeps placeholders working; Revoke stops every use at once; Delete removes the value and its records. Each
secret has an audit list of its uses. Placeholder mode needs the egress proxy and is offered only while it runs.
Details: [features/secrets.md](features/secrets.md).

## 10. Browsers: built-in and shared Chrome

- **Built-in browser** (Browser ▸ Show Browser, ⌃⌘B, or the right panel's Browser tab): WebKit tabs per project for
  previews of dev servers, with responsive sizes, find, Web Inspector and element picking for the composer (⇧⌘C). Share
  a tab with the agent (Browser ▸ Share Tab with Agent), take it over or stop it from the same menu.
- **Shared Chrome** (Browser ▸ Show Shared Chrome, ⌃⌥⌘B, or the Chrome tab): one Chromium running in a container,
  shared by every thread you allow, with one persistent profile like your own browser, so sign-ins are kept. Agents
  drive it with `browse`; each thread gets its own tab group. The first time an agent in a project needs it, you
  approve (Always allows that project; Settings ▸ Browser lists and revokes projects). **Take Over Shared Chrome** gives
  you the mouse and keyboard and **Give Shared Chrome Back to Agents** returns it; every open view follows. Settings ▸
  Browser ▸ Shared Chrome sets the idle stop, profile size, compact display and whether a thread's tabs close when the
  thread is archived or deleted (on by default). The first start builds the image locally, which takes a few minutes and
  pulls a pinned base image from Docker Hub. Details: [features/browser.md](features/browser.md),
  [features/shared-browser.md](features/shared-browser.md).

## 11. Changes, git and worktrees

- **Changes** (⇧⌘D): the diff of this turn, the thread or uncommitted work, unified or side by side, with Next/Previous
  Change (⌃⌘↓ / ⌃⌘↑) and file (⌃⌘→ / ⌃⌘←). Add Review Comment (⇧⌘K) attaches a comment on the selected lines to the
  composer; Revert Hunk, File or Turn put the files back as they were, and Edit ▸ Undo restores the exact bytes; Open
  in Editor (⌘O). The Changes menu also has Commit…, Push (⌃⌘P) and Create Merge Request.
- **Git** menu: Run Suggested Git Action (⌃⌘↩), Git Actions… (⌃⌘G), Commit and Push…, Pull (⌃⌘L), Pull with Rebase,
  Fetch (⌃⌘R), Sync, Abort Merge or Rebase…, Restore Stashed Changes, Clone from GitLab…, New Project…,
  Publish to GitLab… and Switch Remote to HTTPS. Commit messages and merge request text can be written by a model
  (Settings ▸ Models). A failed push after a commit is reported, not hidden. A push you or an agent's card approve goes
  only to the address shown, which needs git 2.46 or Apple Git-155 or later (current Command Line Tools); with an older
  git it is refused with a message and nothing is sent.
- **Worktrees and branches:** Choose Workspace… (⇧⌘E) and Choose Branch… (⇧⌘B) start a thread in a new worktree or on
  another branch; Move Changes to New Worktree… and Remove Worktree… manage them. The Git menu's toggles can remove
  clean worktrees when a thread is settled or archived, and pull the default branch automatically.
- **Rewind:** Git ▸ Edit Last Prompt from Here… takes the thread back to before your last prompt so you can edit and
  resend it; reverting the files too is offered only when no other thread works in the same checkout, and has Undo.

Git runs on the Mac with hooks off. For HTTPS remotes on a configured GitLab instance, BelloCode answers git's
credential request with your GitLab token itself; other remotes use your own git setup. Details:
[features/diff-git.md](features/diff-git.md), [features/git-parity.md](features/git-parity.md).

## 12. GitLab

**Set up:** Settings ▸ GitLab ▸ **Add Instance** with the instance URL and a personal access token (GitLab ▸ User
settings ▸ Access tokens). `read_api` is enough to read; turn on **Allow write actions** and use the `api` scope to let
BelloCode create merge requests, reply, resolve and run jobs. The token is stored in your Keychain; BelloCode warns
before it expires (**Replace Token** to renew). Approve and Merge are hidden unless you turn on **Show Approve and
Merge**, and agents can never approve or merge.

**Use:** the Merge Requests tab (⌃⌘M) shows the thread's linked merge requests with pipelines, approvals and
discussions; Issues (⌃⌘I) and To-dos (⌃⌘Y) of the project. From the GitLab menu: Link or Create Merge Request, Review
Merge Request Diff (⌃⌥⌘R, with inline threads, replies and Submit Review…), Show Failing Job Log and Send Failure to
Agent, Retry Failed Job, Start Thread from Issue, and **Babysit Merge Request**, which wakes the thread when the
pipeline fails or someone comments (within an hourly budget). Text from GitLab reaches the agent marked as untrusted.
Details: [features/gitlab.md](features/gitlab.md).

## 13. Agents working with agents

Agents can delegate a task to a child agent (in the same checkout or a new worktree), create new top-level threads,
read and message other threads in the project, wait for them, and stop them. Child threads are nested under their
parent in the sidebar; their approvals bubble up to the parent and to Needs You. The **Agents** tab (⌃⌘A) shows the
tree with status: Select Next/Previous Agent (⌃⌥⌘↓ / ⌃⌥⌘↑), Open Selected Agent (⌃⌘O), Follow Up Selected Agent…,
Stop Selected Agent and Its Tasks (⌃⌘.) and Go to Parent Thread (⌃⌘U). Limits keep fan-out bounded (two levels below
a top-level thread, six running children). Ask for it in plain words ("delegate the tests to a sub-agent in a
worktree"). Details: [features/orchestration.md](features/orchestration.md).

## 14. Scheduled tasks

Ask an agent to schedule work ("every weekday at 9:00, check the pipeline and summarise failures"). It proposes the
task; the first one in a project waits for your approval on a card (Allow Once, Always in This Project, or Deny), and
any later change an agent makes needs approval again. A task runs every N minutes, at a time on chosen weekdays in a
time zone, or once; each run starts a new thread or sends a message to a thread, with the permission mode you approved.
Settings ▸ Scheduled Tasks (Window ▸ Scheduled Tasks…, ⌃⌘E, or the menu bar item) lists tasks with their next and last
run: edit, switch off, Run Now, Open Thread, or Delete (with Undo). Tasks run while BelloCode is open, even with no
window; a run missed while the Mac slept or the app was closed is caught up once if the task allows it. Details:
[features/orchestration-extras.md](features/orchestration-extras.md).

## 15. Terminal

View ▸ Show Terminal (⌃\`) opens the terminal drawer for the thread's project; the terminal runs in the project's
container. Terminal ▸ New Terminal (⌘T), Split Terminal (⌘D), Close Terminal (⇧⌘W), Next/Previous (⌘} / ⌘{), Clear
(⌘K while the terminal has focus), Send Selection to Composer (⇧⌘L), and Move Terminal to Right Panel. The terminal
keeps its own keys; leave it with ⌃\` or Focus Composer (⌥⌘M). Settings ▸ Terminal sets font size, scrollback, Option
as Meta and paste confirmation. Details: [features/terminal.md](features/terminal.md).

## 16. Keyboard shortcuts

Every command is in the menu bar and the Command Palette (⌘K). Shortcuts below are the defaults in the menu code; a
text field, the terminal and the browser keep their own keys while focused.

| Area | Command | Keys |
| --- | --- | --- |
| App | Settings… | ⌘, |
| File | New Thread / New Window / Add Project… | ⌘N / ⇧⌘N / ⇧⌘O |
| File | Reopen Closed Thread | ⇧⌘T |
| File | Reveal in Finder / Copy Path | ⌥⌘R / ⌃⇧⌘C |
| Edit | Copy as Markdown / Paste Inline | ⌥⇧⌘C / ⌥⌘V |
| Edit | Find in Thread… / Find Next / Find Previous / Use Selection for Find | ⌘F / ⌘G / ⇧⌘G / ⌘E |
| Edit | Search Messages… / Filter Threads… | ⇧⌘F / ⌥⌘F |
| View | Show Sidebar / Show Right Panel / Show Terminal | ⌃⌘S / ⌥⌘I / ⌃\` |
| View | Jump to Latest / Previous Prompt / Next Prompt / Go to Last Failure | ⇧⌘J / ⌥⌘↑ / ⌥⌘↓ / ⌥⌘L |
| View | Focus Composer / Next Region / Previous Region | ⌥⌘M / F6 / ⇧F6 |
| View | Enter Full Screen | ⌃⌘F |
| Go | Command Palette / Quick Open | ⌘K / ⌘P |
| Go | Back / Forward / Next Needs Attention | ⌘[ / ⌘] / ⌥⌘A |
| Thread | Send (outside the composer) / Stop Agent | ⌘↩ / ⌘. |
| Thread | Choose Model… / Permission Mode… / Plan Mode | ⇧⌘M / ⇧⌘A / ⌥⌘P |
| Thread | Ask Every Time / Auto-Accept Edits / Auto / Full Access | ⌃⌥⌘1 / ⌃⌥⌘2 / ⌃⌥⌘3 / ⌃⌥⌘4 |
| Thread | Show Auto Audit Log / Resume Interrupted Thread | ⌃⌘J / ⌃⌥⌘P |
| Thread | Allow Once / Always Allow / Deny or Dismiss / Submit Answer | ⌥⌘Y / ⇧⌥⌘Y / ⌥⌘N / ⌥⌘↩ |
| Thread | Previous Request / Next Request | ⌥⌘[ / ⌥⌘] |
| Thread | Pin Thread / Settle Thread / Snooze Until… / Mark as Unread | ⇧⌘P / ⇧⌘S / ⌥⌘S / ⇧⌘U |
| Thread | Archive Thread / Delete Thread (not while typing) | ⌘⌫ / ⌥⌘⌫ |
| Agents | Show Agents / Open Selected Agent / Go to Parent Thread | ⌃⌘A / ⌃⌘O / ⌃⌘U |
| Agents | Select Next / Previous Agent / Stop Selected Agent and Its Tasks | ⌃⌥⌘↓ / ⌃⌥⌘↑ / ⌃⌘. |
| Terminal | New / Split / Close Terminal | ⌘T / ⌘D / ⇧⌘W |
| Terminal | Next / Previous Terminal / Clear Terminal / Send Selection to Composer | ⌘} / ⌘{ / ⌘K / ⇧⌘L |
| Changes | Show Changes / Add Review Comment… / Open in Editor | ⇧⌘D / ⇧⌘K / ⌘O |
| Changes | Next / Previous Change, Next / Previous Changed File | ⌃⌘↓ / ⌃⌘↑, ⌃⌘→ / ⌃⌘← |
| Changes | Push | ⌃⌘P |
| Changes | Choose Workspace… / Choose Branch… | ⇧⌘E / ⇧⌘B |
| Git | Run Suggested Git Action / Git Actions… | ⌃⌘↩ / ⌃⌘G |
| Git | Pull / Fetch | ⌃⌘L / ⌃⌘R |
| GitLab | Show Merge Requests / Issues / To-dos | ⌃⌘M / ⌃⌘I / ⌃⌘Y |
| GitLab | Review Merge Request Diff / Submit Review… | ⌃⌥⌘R / ⌃⌥⌘↩ |
| GitLab | Next / Previous Review Thread | ⌃⌥⌘] / ⌃⌥⌘[ |
| Browser | Show Browser / Show Shared Chrome | ⌃⌘B / ⌃⌥⌘B |
| Browser | New Browser Tab / New Private Tab / Reopen Closed Tab / Close Browser Tab | ⌃⌘T / ⌃⇧⌘T / ⌃⌥⌘T / ⌃⌘W |
| Browser | Next / Previous Browser Tab | ⌃⇥ / ⌃⇧⇥ |
| Browser | Open Location… / Back / Forward | ⌘L / ⌃⌘[ / ⌃⌘] |
| Browser | Reload Page / Reload from Origin | ⌘R / ⇧⌘R |
| Browser | Zoom In / Zoom Out / Actual Size | ⌘= / ⌘- / ⌘0 |
| Browser | Pick Element for Composer | ⇧⌘C |
| Window | Scheduled Tasks… / Models… | ⌃⌘E / ⌃⌥⌘M |

⌘K is the Command Palette, except while a terminal has focus, where it clears the terminal. The Browser menu's keys
act on the built-in browser (Show Browser), not Shared Chrome. Typed without ⌃⌘ (⌘L, ⌘R, ⇧⌘R, ⌘=, ⌘-, ⌘0, ⇧⌘C,
⌃⇥, ⌃⇧⇥) they act only while the Browser tab is shown and has focus; otherwise the composer, a text field or the
terminal keeps the key. Chosen from the menu, and the ⌃⌘ shortcuts, they work wherever you are. In the composer, Return and ⌘Return follow the send-key setting (section 4).

## 17. Troubleshooting

**macOS says BelloCode cannot be opened / is damaged.** The app is ad-hoc signed, not notarised. Run
`xattr -dr com.apple.quarantine /Applications/BelloCode.app`, or open it once and click **Open Anyway** in System
Settings ▸ Privacy & Security. Do this only for a zip whose SHA-256 matches the published one.

**"Rancher Desktop is not running" / "not installed" / "uses the containerd engine".** Commands are refused rather than
run on the Mac. Install or start Rancher Desktop, switch its container engine to dockerd (moby), then Settings ▸
Containers ▸ Check Again. BelloCode uses Rancher Desktop's socket (`~/.rd/docker.sock`) unless another socket is
configured.

**"Choose an image" / the shared workspace is unavailable.** Set Settings ▸ Containers ▸ Default image, or a project's
own image in Project Environment. If the registry needs a sign-in, use Settings ▸ Containers ▸ Registry sign-in.

**A project is blocked as outside the code roots.** Add its parent folder in Settings ▸ Containers ▸ Code roots, or
switch the project to Project container. A root Rancher Desktop does not share shows instructions for sharing it.

**Pulls from Docker Hub time out or are rate limited.** The egress gateway and the shared Chrome need
`node:22-bookworm-slim` (pinned by digest in [Containers/browser/versions.env](../Containers/browser/versions.env)) from
Docker Hub once. Pull it yourself with Rancher Desktop's CLI, for example
`docker pull node:22-bookworm-slim@sha256:<digest from versions.env>`, then retry; once the image is present it is
reused.

**"Free usage limit reached" or "usage limit".** opencode's free models have an allowance. Connect a provider
(Settings ▸ Accounts or `bellocode-opencode auth login`) and choose a paid model for the thread and in Settings ▸
Models, especially for the Auto reviewer: while the reviewer fails, Auto asks you about everything it would have
reviewed, and the Auto audit entry says so with a button to Settings ▸ Models.

**Shared Chrome shows "Stop not confirmed".** BelloCode could not confirm the browser's container stopped (a Docker
error, or a start that failed and could not be cleaned up). It may still be running. Choose Stop again (Browser ▸ Stop
Shared Chrome, the Stop button in Settings ▸ Browser or in the Shared Chrome panel); if Rancher Desktop itself is down, restart it first. "Sandbox unavailable" means
the container engine cannot run Chromium's sandbox; Settings ▸ Browser explains the fix.

**A message shows "Delivery unknown".** The server did not acknowledge it (for example during a reconnect). The
composer is cleared and a banner above it holds the message: Retry asks the server whether it arrived and sends it
only if it did not (also Thread ▸ Retry Unconfirmed Message). If the server confirms it was not sent, Edit in
Composer puts the text back.

**opencode ignores my `opencode.json`.** Window ▸ opencode… shows the syntax error with its line and column, or says
the file was ignored. Fix it and choose Reload Configuration.

**The agent cannot reach an internal site or package registry.** Check Settings ▸ Containers' network diagnostics and
company CA settings, and that secrets meant for that host list it as a destination.

**Something else.** Window ▸ Verify Container Isolation and Settings ▸ opencode's problem list often name the cause.
The feature notes' "Verification" and "Not verified" sections list known limits.
