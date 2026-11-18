import AppKit
import BelloCore
import ContainerKit
import DesignSystem
import Engine
import Foundation
import MockOpenCode
import SwiftUI

/// Execution-mode states of `--snapshot containers` (docs/features/containers.md, "Execution modes"): a thread in a
/// shared-workspace project (header and context line name the mode) whose agent hit a refused Docker request, the
/// mode picker with its explanations, Settings ▸ Containers ▸ Execution and Code roots, and the dev container section.
extension SnapshotRunner {
    func runExecutionModes(engine: Engine, driver: ShellDriver, workspace: WorkspaceController) async -> [String] {
        func wanted(_ state: String) -> Bool { only.isEmpty || only.contains(state) }
        var written: [String] = []
        let environments = engine.environments
        let projects = engine.root.projects
        guard projects.count >= 3 else { return [] }
        let shared = projects[1].directory
        let host = projects[2].directory
        // The default image comes from the organisation's registry (the snapshot's managed image policy).
        var defaults = environments.defaults
        defaults.defaultImage = "registry.acme.internal/dev/base:2026.11"
        await environments.setDefaults(defaults)
        await environments.setCodeRoots([(shared as NSString).deletingLastPathComponent])
        await environments.setMode(nil, for: shared)
        await environments.setMode(.hostDocker, for: host)
        environments.activate(shared)
        let sharedEnvironment = environments.environment(for: shared)
        _ = await waitUntil(timeout: .seconds(5)) { sharedEnvironment.phase == .ready }
        let refusal = "BelloCode refused this Docker request: mounting /Users/dev/.ssh is not allowed: only folders inside \((shared as NSString).deletingLastPathComponent) can be mounted. Use a path in the project, or a named volume."
        environments.recordDockerRefusal(.init(scope: sharedEnvironment.containerKey, method: "POST", path: "/containers/create", message: refusal, date: Date()))

        // 1. A thread in the shared workspace: header and context line, the agent's docker request refused.
        // A thread that is not already running a turn (the mock has some that are).
        if wanted("exec-thread"), let thread = workspace.projectModel(projects[1])?.sessionIDs.first(where: { id in
            !(workspace.threadModel(id).session?.isRunning ?? false)
        }) {
            _ = await driver.select(.thread(thread))
            let model = workspace.threadModel(thread)
            _ = await waitUntil(timeout: .seconds(5)) { model.phase == .ready }
            await runtime.enqueueMockScript(
                TurnScript(name: "snapshot-docker-refused") {
                    TurnStep.text("I'll start the API's database with its compose file and run the integration tests against it.\n\n")
                    TurnStep.tool(
                        "bash", input: ["command": "docker compose up -d db", "description": "Start the test database"],
                        output: "[+] Running 1/1\n ✔ Network api_default  Created\nError response from daemon: \(refusal)\n", duration: 400,
                        error: StructuredError(type: "ToolError", message: "Error response from daemon: \(refusal)"))
                    TurnStep.text("BelloCode's Docker endpoint refused the bind mount of ~/.ssh in compose.yaml. I'll switch the `db` service to a named volume (`pgdata:/var/lib/postgresql/data`), which the endpoint allows, and retry.")
                }, for: thread)
            driver.type("Run the integration tests against a real database.")
            driver.send()
            try? await Task.sleep(for: .milliseconds(800))
            _ = await waitUntil(timeout: .seconds(20)) { model.messageIDs.count >= 2 && !(model.session?.isRunning ?? true) }
            try? await Task.sleep(for: .milliseconds(500))
            driver.settle(10)
            try? await Task.sleep(for: .milliseconds(300))
            driver.settle(6)
            written += await render(driver, state: "exec-thread")
        }
        // 2. The mode picker with explanations, after switching (Undo offered), and the refused-request list.
        if wanted("exec-mode-picker") {
            written += await renderComponent(state: "exec-mode-picker") {
                SettingsPaneBody {
                    SettingsGroup("Where commands run", footer: "opencode and its file tools always edit files on this Mac. This decides where the agent's commands, terminals and MCP servers run.") {
                        ExecutionModePickerView(service: environments, environment: sharedEnvironment)
                    }
                    SettingsGroup("Docker from the workspace", footer: "docker, docker compose and docker build inside the container reach BelloCode's filtered endpoint: only this workspace's containers, volumes and networks, bind mounts inside the code roots, no privileged or host access.") {
                        DockerRefusalsView(refusals: environments.dockerRefusals.filter { $0.scope == sharedEnvironment.containerKey })
                    }
                }
                .frame(width: 600)
            }
        }
        // 3. Settings ▸ Containers ▸ Execution and Code roots (one root mounted, one refused with its reason).
        if wanted("exec-code-roots") {
            await environments.setCodeRoots([(shared as NSString).deletingLastPathComponent, NSHomeDirectory()])
            written += await renderComponent(state: "exec-code-roots") {
                SettingsPaneBody {
                    SettingsGroup("Execution", footer: "Where commands run for projects that have not chosen. opencode and its file tools always edit files on this Mac; each project can choose its own mode in Project Settings ▸ Environment.") {
                        DefaultExecutionModeView(service: environments)
                    }
                    SettingsGroup("Code roots", footer: "Folders your repositories live in. The shared workspace mounts each read-write at the same path, and paths inside them count as in scope for approvals and risk notices.") {
                        CodeRootsSettingsView(service: environments)
                    }
                }
                .frame(width: 600)
            }
            await environments.setCodeRoots([(shared as NSString).deletingLastPathComponent])
        }
        // 4. A project container from a dev container file: supported settings, refused ones, lifecycle to review.
        if wanted("exec-devcontainer") {
            let folder = (host as NSString).appendingPathComponent(".devcontainer")
            let file = (folder as NSString).appendingPathComponent("devcontainer.json")
            let existed = FileManager.default.fileExists(atPath: file)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if !existed {
                try? Data(Self.devContainerExample.utf8).write(to: URL(filePath: file))
            }
            defer { if !existed { try? FileManager.default.removeItem(atPath: folder) } }
            await environments.setMode(.projectContainer, for: host)
            var settings = environments.environment(for: host).settings
            settings.useDevContainer = true
            await environments.update(host, settings: settings)
            if let plan = environments.devContainerFile(host) {
                let environment = environments.environment(for: host)
                written += await renderComponent(state: "exec-devcontainer") {
                    SettingsPaneBody {
                        SettingsGroup("Dev container", footer: "A safe subset of the Dev Container specification: image or build, environment, user, forwarded ports and post-create/start commands after review. Commands that would run on this Mac, Features, privileges and extra mounts are refused.") {
                            DevContainerSectionView(service: environments, environment: environment, plan: plan)
                        }
                    }
                    .frame(width: 600)
                }
            }
            await environments.setMode(.hostDocker, for: host)
        }
        return written
    }

    static let devContainerExample = """
    // The API's dev container
    {
      "name": "api",
      "build": { "dockerfile": "Dockerfile", "args": { "NODE": "22" } },
      "containerEnv": { "NODE_ENV": "development" },
      "remoteUser": "node",
      "forwardPorts": [3000],
      "initializeCommand": "./scripts/fetch-secrets.sh",
      "features": { "ghcr.io/devcontainers/features/github-cli:1": {} },
      "postCreateCommand": "npm ci",
      "postStartCommand": "npm run db:migrate",
      "customizations": { "vscode": { "extensions": ["dbaeumer.vscode-eslint"] } }
    }
    """
}
