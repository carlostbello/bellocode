# opencode contract diff: opencode-2.3.0 -> opencode-2.3.2

## Affecting BelloCode (28)

- **DELETE /api/experimental/schedule/{scheduleID}** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **GET /api/experimental/schedule/{scheduleID}** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **POST /api/experimental/schedule** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **GET /api/config** changed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **GET /api/model** changed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient.swift
- **GET /api/model/default** changed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient.swift
- **schema Config.InfoEncoded** changed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift; properties changed: compaction, experimental
- **schema Model.Type** changed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift, Sources/OpenCodeKit/HTTP/OpenCodeClient.swift; enum added: video
- **schema Schedule.Action** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Action.Prompt** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Condition** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Condition.Code** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Condition.Shell** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.ConditionInput** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.CreatePayload** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Duration** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Ends** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.ID** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Info** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Outcome** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.Status** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.When** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.When.At** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.When.Cron** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.When.Every** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.When.In** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema Schedule.WhenInput** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- **schema ScheduleNotFoundErrorEncoded** removed; consumers: Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift

## Endpoints (19 changes)

- removed `DELETE /api/experimental/schedule/{scheduleID}` (experimental) used by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `GET /api/experimental/schedule` (experimental)
- removed `GET /api/experimental/schedule/{scheduleID}` (experimental) used by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `POST /api/experimental/schedule` (experimental) used by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `POST /api/experimental/schedule/{scheduleID}/pause` (experimental)
- removed `POST /api/experimental/schedule/{scheduleID}/resume` (experimental)
- added `DELETE /api/experimental/automation/{automationID}` (experimental)
- added `GET /api/experimental/automation` (experimental)
- added `GET /api/experimental/automation/{automationID}` (experimental)
- added `GET /api/experimental/blob/{id}` (experimental)
- added `GET /api/experimental/generate/video/{id}` (experimental)
- added `POST /api/experimental/automation` (experimental)
- added `POST /api/experimental/automation/{automationID}/pause` (experimental)
- added `POST /api/experimental/automation/{automationID}/resume` (experimental)
- added `POST /api/experimental/generate/video` (experimental)
- changed `GET /api/config` used by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift: schemas changed: Config.InfoEncoded, Model.Type
- changed `GET /api/experimental/job` (experimental): schemas changed: Job.Info, Job.Kind; schemas now referenced: Job.CodeMode
- changed `GET /api/model` used by Sources/OpenCodeKit/HTTP/OpenCodeClient.swift: schemas changed: Model.Type
- changed `GET /api/model/default` used by Sources/OpenCodeKit/HTTP/OpenCodeClient.swift: schemas changed: Model.Type

## Schemas (61 changes)

- added `Automation.Action`
- added `Automation.Action.Code`
- added `Automation.Action.Prompt`
- added `Automation.ActionInput`
- added `Automation.CodeActionInput`
- added `Automation.CreatePayload`
- added `Automation.Duration`
- added `Automation.ID`
- added `Automation.Info`
- added `Automation.Outcome`
- added `Automation.PromptActionInput`
- added `Automation.Status`
- added `Automation.Target`
- added `Automation.Trigger`
- added `Automation.Trigger.At`
- added `Automation.Trigger.Cron`
- added `Automation.Trigger.Event`
- added `Automation.Trigger.Every`
- added `Automation.Trigger_1`
- added `AutomationNotFoundErrorEncoded`
- added `Blob.ID`
- added `Blob.Info`
- added `BlobNotFoundErrorEncoded`
- changed `Config.InfoEncoded` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift: properties changed: compaction, experimental
- added `Generate.ImageFile`
- added `Generate.VideoAspect`
- added `Generate.VideoCompleted`
- added `Generate.VideoError`
- added `Generate.VideoErrorReason`
- added `Generate.VideoID`
- added `Generate.VideoJob`
- added `Generate.VideoRequest`
- added `Generate.VideoResolution`
- added `Generate.VideoRunning`
- added `GenerateVideoCreateResponse`
- added `GenerateVideoGetResponse`
- added `Job.CodeMode`
- changed `Job.Info`: changed (structure)
- changed `Job.Kind`: enum added: codemode
- changed `Model.Type` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift, Sources/OpenCodeKit/HTTP/OpenCodeClient.swift: enum added: video
- removed `Schedule.Action` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Action.Prompt` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Condition` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Condition.Code` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Condition.Shell` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.ConditionInput` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.CreatePayload` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Duration` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Ends` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.ID` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Info` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Outcome` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.Status` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.When` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.When.At` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.When.Cron` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.When.Every` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.When.In` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `Schedule.WhenInput` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- removed `ScheduleNotFoundErrorEncoded` decoded by Sources/OpenCodeKit/HTTP/OpenCodeClient+Isolation.swift
- added `VideoNotFoundErrorEncoded`

## Events

- in the schema: added none; removed none
- in the recorded turn: newly seen ['artifact.updated']; no longer seen ['vcs.branch.updated', 'worktree.resolved']
- handled by BelloCode but removed: none

## Bridges

- experimental.browser: static v4 -> v4; attach accepted [4] -> [4]; granted rules changed: False
- BelloCode plugin: loaded True; contract 1 -> 1; tools changed: False

## Built-ins

- agents: {"added": [], "removed": [], "permissionsChanged": []}
- skills: {"added": [], "removed": []}
- commands: {"added": [], "removed": []}
- plugins: {"added": ["opencode.tool.automation"], "removed": ["opencode.tool.schedule"]}
- tools: {"added": [], "removed": []}
- promptFiles: {"added": ["automation.txt"], "removed": ["schedule.txt"]}

## Permission evaluation (0 differences)


## Model catalog

- anthropic: added none; removed none
- anthropic:nonchat: added none; removed none
- free: added ['opencode/hy4-flash-free']; removed ['opencode/minimax-m3.1-flash-free']
- google: added none; removed none
- google:nonchat: added none; removed none
- openai: added ['gpt-5.4-flex', 'gpt-5.5-flex', 'gpt-5.6-luna-flex', 'gpt-5.6-sol-flex', 'gpt-5.6-terra-flex', 'gpt-6-astra-flex', 'gpt-6-cyber', 'gpt-6-luna-flex', 'gpt-6-sol-flex', 'gpt-6.1-sol-flex', 'gpt-6.1-terra-flex', 'gpt-6.2-astra', 'gpt-6.2-astra-fast', 'gpt-6.2-astra-pro', 'gpt-6.2-astra-ultrafast', 'gpt-6.2-sol', 'gpt-6.2-sol-fast', 'gpt-6.2-sol-pro', 'gpt-6.2-sol-ultrafast']; removed none
- openai:nonchat: added none; removed none
