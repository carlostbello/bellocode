# Models for tasks (Settings ▸ Models)

Status: built 2026-11-20 on opencode 2.3.2 (pinned), MockOpenCode and the real binary with a local mock provider.
Owner request: "Can we do a model selector for certain tasks? If I add a provider via opencode is there a menu for me
to set the model?" Window ▸ Models… (⌃⌥⌘M) or Settings ▸ Models.

## Rows

Each row is the composer's model picker (`ModelPickerModel`/`ModelPickerView`) over the catalog of connected
providers: search, provider sections, Free / price, context, effort (⇥), disabled rows with the reason, Connect….
`ModelSettingButton` shows "Provider · Model" with a Free / Paid badge, or ⚠ Unavailable when the saved model's
provider is gone or disabled. Choices that are not one model are listed first ("Use").

| Row | Choices | Stored in |
| --- | --- | --- |
| Default for new threads | opencode's choice, or a model | opencode `model` in BelloCode's isolated global `opencode.json` |
| Small model (thread titles) | opencode's choice, or a model | opencode `agents.title.model` (2.3.2 has no `small_model`; its legacy migration maps `small_model` to this key, measured in the binary) |
| Auto reviewer | Same as thread (default), Server default, a model | `app_preference` `auto.reviewer` (`AutoReviewer.Settings.model` as a `ModelChoice` token) |
| Git & GitLab writing | Same as thread (default), Small model, a model | `app_preference` `models.background` |
| Delegated threads and scheduled tasks | Same as parent (default), Server default, a model | `models.background`, mirrored to `<data>/bellocode-models.json` for the plugin |

No migration: `app_preference` already exists. opencode 2.3.2's config PATCH (`experimental.config.update`) only
accepts `shell` (Contracts/opencode-2.3.2/openapi.json), so the two opencode values are written with `JSONCEditor`,
an in-place JSONC edit that keeps comments and formatting and refuses a file that does not parse, then
`POST /api/location/reload`. The edited text is swapped in atomically (`RENAME_SWAP`) and the displaced file is
checked against the one edited: a save that landed in between is put back and edited again, and a further one is kept
as `opencode.json.conflict-<time>` with the edit failing to say so; another program's save is never silently replaced
(v1.0.1 AF24, `ModelSettingsService`). A reload cancels pending approvals and questions: the pane asks first ("Reload Now" or
"Save Only"; saved-only shows "Saved; not applied yet" with Reload opencode Now). Compaction ("summaries") keeps the
thread's model: a smaller model's context window can be too small for it.

## Resolution (`BackgroundModelResolver`, pure, unit-tested)

Order: the owner's setting, then the thread's model, then opencode's default, then a fast catalogue fallback. A saved
model that is not usable now falls through to the next step. **Reviewer:** while a connected provider offers a paid
model, the automatic steps never pick a free one (opencode's free tier refuses `generate.text` once its allowance is
used: "Free usage limit reached", which made Auto escalate everything); the fallback is paid-first, fast families
first (`claude-haiku`, `gemini-flash`, …, then names with mini/flash/haiku/…). A free model the owner picks explicitly
is used. **Git & GitLab text:** Same as thread is `session.generate` (the thread's model and context; that endpoint has
no model parameter); a chosen model or the small model is `generate.text` with `model` (stateless; the MR prompt now
stands on the commits alone). **Delegated threads:** `delegate_task`'s model, else the agent's, else the owner's
default (read from `bellocode-models.json` at each call, no restart). **Scheduled runs:** the task's model, else none if
its agent has one, else the owner's default, "Same as parent" being the thread that created the schedule.
If the `models.background` preference cannot be read, the plugin mirror is left as it was and the read error stays
shown; a change first re-reads the preference and is refused while it is unreadable, so the fallback is never saved
as the setting (v1.0.1 AF27).

## Provider refusals (`BackgroundModelError`)

Classified from opencode's typed errors (`ProviderRequestError` `reason`, `ModelNotFoundError`, …) and the provider's
wording (`insufficient_quota`, "usage limit", billing, credits): quota, rate limited, sign-in refused, unavailable,
overloaded. The message names the task and the model and says what to do, e.g. "Commit message model OpenCode ·
Big Pickle hit its provider's usage limit. Choose a paid model in Settings ▸ Models." Shown in the Auto audit entry
(reason `provider_limit` etc., with an Open Settings ▸ Models… button), the commit form and the merge request form.
The provider's own text is never stored or logged.

## Discoverability of the per-thread picker

The composer's model button shows the thread's model (else the catalog default) and opens the picker (⇧⌘M).
Credential and integration events (`credential.updated`, `credential.switched`, `integration.updated`,
`models-dev.refreshed`) now refresh every cached location's catalog, not only the default one, so a provider added in
Settings ▸ Accounts or with `bellocode-opencode auth login` (which goes through the running server) shows in every
project's picker and in Settings ▸ Models.

## Verification

`make test` (new: `BackgroundModelResolverTests`, `BackgroundModelMockTests`, `JSONCEditorTests`, picker choices,
menu item); `Plugin` `bun test` (64, incl. `childModel`); opt-in real binary
`BELLOCODE_CONFIG_REAL=1 swift test --filter OpenCodeConfigRealBinary` (`modelsPaneSettingsAreAppliedByOpencode`:
`model.default` and the `title` agent's model follow the file after the reload, `generate.text` reaches the chosen
model, an OpenAI-style `insufficient_quota` 429 classifies as quota). Snapshots: `.build/debug/BelloCode --snapshot
models` (`models-{default,chosen,row-picker,window}-{light,dark}.png`; copies in `docs/snapshots/settings-models-*.png`).

## Section E checklist

Purpose and context: each row says what it drives and what it resolves to now ("Now: Mock AI · Mock Small").
States: loading (no catalog: "Loading the catalog…"), empty (opencode's choice), success, unavailable (⚠ + word),
failure (opencode.json syntax error with position, write failure, reload failure: "Saved… applies at the next
reload"), offline (catalog cached). Keyboard: Window ▸ Models… ⌃⌥⌘M (unique, tested); each row is a button (Space/↩)
opening the picker (↑↓ ↩ ⇥ esc). Status is never colour-only (badge words, ⚠ + "Unavailable"). Reversible: every
choice applies at once and is changed back the same way; the only confirmation is the reload that would cancel
approvals. Not exercised: VoiceOver, a person at the screen, two windows.

## Unverified / follow-ups

- A live reviewer call on a paid provider (no paid credentials in this environment); the real-binary test covers the
  generation path and the error shape with a local provider.
- opencode's own free-tier error text on the real Zen service (mapped by wording and `ProviderRequestError`; the
  live text was not captured here).
- `create_threads` (agent-created top-level threads) still use opencode's default when no model is given.
- A thread title already generated keeps its model; the small model applies to new titles.
