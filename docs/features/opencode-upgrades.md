# opencode upgrades

BelloCode bundles one pinned opencode and leans on its experimental surfaces (client MCP, plugin RPC, the
`experimental.browser` v4 bridge, instruction entries, permission rule order, persistent PTYs, automations, events).
Every bump goes through two commands; neither moves the pin.

## The pin

`Scripts/opencode-version` is the single source of truth. `fetch-opencode.sh` and `make-app.sh` read it; make-app
writes it into `Info.plist` (`BelloCodeOpenCodeVersion`); `OpenCodePin` (BelloCore) gives it to the app (Settings ▸
General ▸ About, the About panel's credits), the mock (`/api/info` version) and the tests (vendored binary,
`Contracts/opencode-<pin>/`). `BELLOCODE_OPENCODE_VERSION=x.y.z` overrides the file for one run. Bumping is one line
plus the new contract directory; `Scripts/opencode-checksums` keeps a line per recorded version.

## Commands

```
make opencode-upgrade VERSION=2.3.2   # download, verify, capture Contracts/opencode-2.3.2/, diff (1 prompt)
make opencode-verify  VERSION=2.3.2   # the gate; Scripts/opencode-verify.sh 2.3.2 --quick runs it without prompts
echo 2.3.2 > Scripts/opencode-version # the bump, once the gate is green
```

**Upgrade** downloads the darwin-arm64 and darwin-x64-baseline archives, checks each SHA-256 against the
`anomalyco/homebrew-tap` `opencode-v2.rb` formula of that release (the commit "update opencode-v2 to x.y.z"), else
records the observed digest as `first-seen` (a human confirms it before pinning). It installs
`Vendor/opencode/<v>/opencode`, checks `--version`, and runs `Scripts/opencode_contract.py capture` in sandboxes
(temporary HOME/XDG/TMPDIR, own process group, killed after): `openapi.json`; `events-sample.sse` (one turn on
`opencode/big-pickle`: a shell call approved once, then a reply); `surface.json` (agents and their rules, skills,
commands, built-in plugins, tool names, embedded prompts, the browser version read from the binary and probed by
attaching at v3/v4/v5, the granted browser rules, the BelloCode plugin's `bellocode.info` contract and tools,
permission effects for build/plan × none/ask/autoEdit/fullAccess × ten actions); `catalog*.json` (free models, and
the OpenAI, Anthropic and Google catalogs listed with a dummy key stored only in the sandbox, no prompt to them).
Then `diff` writes `upgrade-diff.json` and `UPGRADE-DIFF.md` against the pinned contract (`FROM=` for another).

**Reading the diff.** "Affecting BelloCode" lists only changes with a consumer: operations are matched to the Swift
files that call them (operationId labels and `["api", …]` paths), schemas to the callers of every operation that
reaches them and to DTOs that name them in backticks, events to `OpenCodeEvent.swift`. The rest is informational:
endpoints (experimental flagged), schemas with property/required/enum notes, event types in the schema and the
recorded turn, bridge and plugin versions, built-ins, permission-effect changes and catalog additions/removals.

## What the gate checks

| Area | Covers |
| --- | --- |
| unit-and-recorded-contract | the whole default suite on the candidate's contract: SSE/decoder tests on its recorded turn, catalog decode, mapping and picker search for every new model, the default real-binary suites (integration, git, terminal, worktree move) |
| mock-vs-real-contract | `RealBinaryContract`: the same request sequence on MockOpenCode and the binary, shapes and event order compared |
| agent-contract-real, browser-bridge-attach, permission-policy-real | agents/auth/credentials, attach v4 → `attached` → granted rules → state ack → `closed`, mode rules as reported by the server |
| g2, prompt-retry, orchestration, extras, gitlab, shell-e2e | the opt-in real-binary suites (prompts 1, 2, 5, 7, 3, 2) |
| containers-live, plugin-tests | Rancher Desktop suites (used as is, settings never read); the plugin's bun tests in a container |
| app-bundle, smoke, isolation-self-check, bundled-version, e2e-containers | a candidate bundle in `build/opencode-verify/<v>/`, `--smoke-test` (Isolated required), Info.plist, the container e2e (2 prompts) |
| no-processes-left | nothing from the candidate binary or the verify bundle still runs |

A run sends at most 22 prompts, all on zero-cost built-in models. Skipped opt-in tests fail their area. The report is
`build/opencode-verify/<v>/REPORT.md` (+ `report.json`, `logs/<area>.log`): a table per area, then every contract
change that touches BelloCode with its consumers. Fix, rerun, bump when all green; then `make test` and `make smoke`.

## Still needs a human

- Confirming a `first-seen` digest. Signing in to a paid provider and running a new model (we verify catalog presence,
  mapping and selection only). On-screen checks of Settings ▸ General ▸ About and the About panel. Reading new
  embedded prompts and skills for behaviour changes the tests cannot see.

## 2.3.0 → 2.3.2 (2.3.2 adds nothing to 2.3.1's API; only its catalog differs)

- **Schedules became automations (2.3.1).** `/api/experimental/schedule*` and shell conditions are gone;
  `/api/experimental/automation*` runs a prompt or a Code Mode program (no shell of its own) and answers 403 unless
  `experimental.automations` is set. The isolation self-check probed schedules and would have reported Problem; it now
  probes automations (Off) and keeps the schedule probe for older servers. Also new: blobs, video generation
  (`Model.Type` gains `video`, `Job.Kind` gains `codemode`), `Config` compaction/experimental fields (raw to us).
- **New models (2.3.2 catalog).** OpenAI: `gpt-6.2-astra`, `-fast`, `-pro`, `-ultrafast`; `gpt-6.2-sol`, `-fast`, `-pro`,
  `-ultrafast`; `gpt-6-cyber`; `-flex` tiers for 5.4, 5.5, 5.6 luna/sol/terra, 6 astra/luna/sol, 6.1 sol/terra. Free:
  `opencode/hy4-flash-free` added, `opencode/minimax-m3.1-flash-free` removed. Tiers share one API `modelID`
  (`gpt-6.2-astra-fast` → `gpt-6.2-astra`) and refs name the entry `id`; BelloCode keyed models by `modelID`, which
  collapsed tiers onto one row and sent the base model. Fixed: entries are keyed and referenced by `id`.
- **Events.** `artifact.updated` now arrives when a location activates: mapped to a resource signal, treated as bootstrap
  noise by the mock comparison. No event type added or removed in the schema.
- **Unchanged.** Browser bridge v4 and its granted rules, plugin contract 1 and its 14 tools, agents, skills, commands,
  permission effects for every mode probe, client MCP, PTY and instruction-entry routes.
