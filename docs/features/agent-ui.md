# Approvals, questions, modes, model picker and accounts (M1-D)

Status: done 2026-11-16 against opencode 2.3.0 (sandboxed real binary) and MockOpenCode. Module `AgentUI`.

## Mounting (`import AgentUI`; all `@MainActor`, styled by `AgentUIStyle`, desktop density)

- `AgentUIFactories.pendingRequestStack(thread:engine:style:) -> (NSView, PendingRequestStackModel)`: pin directly above
  the composer, width-constrained; height follows content (0 when empty). Add `requestMenuItems(for: model)` to the
  Thread menu (Allow Once ⌥⌘Y, Always Allow ⇧⌥⌘Y, Deny/Dismiss ⌥⌘N, Submit ⌥⌘↩, Previous/Next ⌥⌘[ / ⌥⌘]).
- Composer controls bar: `permissionModeControl(thread:engine:)` (⇧⌘A), `planToggle(thread:)` (⌥⌘P),
  `modelPicker(thread:engine:auth:onConnect:)` (⇧⌘M; `onConnect(integrationID?)` should open `providerConnect`).
- Shell/Settings: `onboarding(auth:engine:importSource:onFinish:)`, `accountsSettings(auth:importSource:)`,
  `providerConnect(auth:integrationID:onDone:)` return `NSViewController`s. Create one `AuthService` per app with
  `engine.makeAuthService(openURL: { NSWorkspace.shared.open($0) })`; call `shutdown()` before `engine.stop()`.
- SwiftUI views are public too (`PendingRequestStackView`, `PermissionModePicker`, `ModelPickerButton`/`View`, …).
  Protocols `PendingRequestSource` / `AgentModeSource` (ThreadModel conforms) keep views testable. No SwiftUI macro
  plugin ships with Command Line Tools, so `@State` cannot compile: use `@StateObject … ViewState(x)`.

## Permission modes (verified with `POST /api/session/{id}/permission`, which evaluates without a prompt)

opencode evaluates agent rules, then session rules, then saved project rules; the last match wins. Session rules
therefore override the agent's own (a session `* allow` also lifts plan's `edit: deny` and the `.env` asks).
Mapping (`PermissionModeRules.rules(for:agentRules:)`): mode rules, then the agent's denies on the governed actions
(`edit`, `shell`, `external_directory`) and their exceptions. Not every deny: `browser: deny` changes at runtime.

| Mode / agent | read | `.env` | edit | shell | outside project |
| --- | --- | --- | --- | --- | --- |
| Ask (`edit,shell,external_directory: ask`) / build | allow | ask | ask | ask | ask |
| Auto-edit (`edit: allow`, others ask) / build | allow | ask | allow | ask | ask |
| Full access (`* *: allow`) / build | allow | allow | allow | allow | allow |
| Any mode / plan (`+ edit *: deny, edit ~/.opencode/plan/*: allow`) | as above | as above | **deny** | as above | as above |
| No rules (opencode default) / build | allow | ask | allow | allow | allow |

So `*` does grant full access, including `.env` reads. `setAgent` rewrites the rules for the new agent. Children copy
the parent's rules at creation. "Always" saves a rule per **project** (every thread, survives restarts;
`GET /api/permission/saved?projectID=`; without `projectID` the list is empty). A cold location answers 404 for
`agent.get` and `connect/key`; the Engine retries the agent lookup.

## Auth flow (`AuthService`, Engine)

`idle → submitting → succeeded | failed(server reason; inputs kept; Retry)` for key/external.
`idle → starting → waitingForBrowser(url, canPaste) | waitingForCode(url, error?) → verifying → succeeded`; polling
ends in `failed | expired`; `cancel()` → `cancelled` and `DELETE` on the server. Local expiry uses the attempt's lifetime
(`expires − created`) from now, never the server clock. Command logins: `starting → runningCommand(output) → …`.
Success is reported after the integration and credential lists are refreshed. Real 2.3.0: 240 integrations with
`OPENCODE_DISABLE_MODELS_FETCH=1` (the app's setting), 332 without (key 330, env 331, oauth 10, external 3, command 0);
a cold list is empty for a few seconds (retried);
`connect/key` stores **any** key without contacting the provider (even empty: BelloCode trims and rejects empty);
missing required form field → 400 "Missing required form field: resourceName". Credentials are decoded without
secrets (`CredentialSummary`). BelloCode retains no provider secret, so nothing goes to the Keychain.
Import: `opencode auth list --standalone --format json` (preview, no secrets) then `auth export --standalone` of the
source install's own binary piped into `auth import --server <url>` (bundled binary, password via env, throw-away
XDG). Secrets never enter BelloCode's memory. Import prints its summary on stderr; it is idempotent (skips IDs).

## Additions outside AgentUI

- OpenCodeKit: integration list/get, connect key/external/OAuth/command (+status/complete/cancel), credential
  list (non-secret)/rename/remove/activate, `evaluatePermission`, saved permissions, `agent(_:)`,
  `ServerCredentials.clientEnvironment`.
- Engine: `AuthService`, `CredentialImporter`/`CredentialImportSource`, agent-aware `PermissionModeRules`, child
  requests routed to and listed in every ancestor `ThreadModel.pendingRequests`, `ModelPreferencesModel`
  (`engine.modelPreferences`, table `app_preference`, migration `v2-app-preferences`). BelloCore: `QuestionField`
  hidden/conditions/validation, `ModelEntry` costs and release, `ProviderEntry.integrationID`.
- MockOpenCode: integrations (`MockIntegration.standard`), credentials, scripted OAuth/command (`setOAuthBehaviour`),
  cold lists, rule evaluation on permission create, project-saved "always" rules, child rule inheritance.

## Verification

`swift test` (AgentUI 21, Engine 69, Mock 52, OpenCodeKit 88). `BELLOCODE_CONTRACT_REAL=1 swift test --filter
AgentRealBinary` (integration list, fake-key connect, mode table above, import between two sandboxes).
`swift run AgentUIDemo --all` drives 5 scenarios (requests, modes, models, onboarding, accounts) with 60 checks and
writes 50 PNGs (light and dark) to `build/snapshots/agent-ui/`.

## Section E checklist (docs/research/03)

Pass: purpose/context (operation, directory, agent, thread, child origin, project scope of "always"); states for
connect/accounts/import (empty, loading, failure+retry, cancel, expiry, success); approvals (5 concurrent incl. a
child's, navigate, deny with note, failed reply stays, removal only after the server's 204); onboarding (free models
first, invalid input recovery, no secret in logs/descriptions); no colour-only status; no implicit animation.
Partial: keyboard (all actions have shortcuts/menu items, but Tab/focus order was not driven); persistence (picker
preferences persist; typed question answers survive navigation, not relaunch); context lacks the branch (no VCS
model yet). Unverified: VoiceOver and timing on a live window (announcements are unit-tested once-only), large text,
localization. N/A here: streaming, artifacts, multi-window.

## Unverified

Real OAuth and device/code flows with real providers (needs the owner's accounts); command login (no 2.3.0
integration offers one); a real permission/question from a model turn (shapes come from the contract, the recorded
stream and `session.permission.create`); `integration.updated`/`credential.*` events driving refresh (AuthService
refreshes after its own actions only); import against a real user install (only sandbox to sandbox, by design).
