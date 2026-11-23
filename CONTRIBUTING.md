# Contributing

BelloCode is built for one organisation and no licence has been chosen yet (all rights reserved), so outside
contributions cannot be accepted until one is. These notes are for people working on the code with the owner.

## Rules

[AGENTS.md](AGENTS.md) applies to every change, by people and agents alike: its engineering rules (stable server IDs,
coalesced stream updates, bounded caches and queues, main-actor discipline, owned and cancellable tasks, continuous
clock timers, no logged content or credentials) and its UX rules (menu item and shortcut for every action, Undo for
reversible actions, visible project, branch and worktree, every state covered). Read [docs/PLAN.md](docs/PLAN.md) and
the feature note for the area you touch before changing it. Never read or log credentials, and never touch a
developer's own opencode configuration or data.

## Build and test

Use the `make` targets; they export the `SWIFTTERM_BUILD_*` values that keep SwiftTerm's build plugin from stalling
(export them yourself if you run `swift` directly).

```sh
make fetch          # pinned opencode and ripgrep into Vendor/ (once per checkout)
make build          # swift build
make test           # swift test: must pass before you commit
make plugin-test    # the plugin's bun tests, in a container
make app && make smoke   # assemble build/BelloCode.app and check the bundled server
```

- Tests use Swift Testing (`import Testing`); XCTest is not available with Command Line Tools.
- A suite that touches sockets, pipes, processes or web views carries `.timeLimit(.minutes(3))` (10 for suites that
  run the real opencode binary). Wait on gates or barriers, never on sleeps, and assert the work, not its timing.
- New logic gets tests against MockOpenCode or the recorded contracts in `Contracts/`. Check every opencode endpoint
  against the pinned OpenAPI document there, never from memory.
- Opt-in live and real-binary suites are listed in [README.md](README.md#testing). Run the ones for the area you changed.
- UI changes: render the view to a PNG from inside the process (the `--snapshot` launch argument in debug builds writes
  under `build/snapshots/`) and look at it. Run the acceptance checklist in
  [docs/research/03-ux-patterns.md](docs/research/03-ux-patterns.md), section E.

## Commits

- One logical change per commit. The subject names the area and the change in plain words ("Git: verified stash
  restore"), with a finding ID in parentheses when it fixes a review finding ("(AF05)"). The body says what was wrong,
  what changed and how it was tested.
- Work on a branch; do not commit straight to `main` or `develop`.
- Update the feature note in `docs/features/` when behaviour changes, and add a line to
  [docs/RELEASE-NOTES.md](docs/RELEASE-NOTES.md) under "Unreleased" when users will notice it.
- A database change is a new, named, versioned migration with a test.
- Do not commit build output, `Vendor/`, logs, local databases or anything holding a credential; `.gitignore` covers
  the usual paths.
