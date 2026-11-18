import BelloCore
import Darwin
import Foundation
import Testing

@testable import Engine
@testable import OpenCodeKit

/// Git parity against the pinned opencode (opt-in: `BELLOCODE_GIT_REAL=1 swift test --filter GitParityRealBinary`):
/// a checkpoint is captured before the turn, `session.generate` proposes a commit message and a branch name (three
/// short runs on the zero-cost default model in all), and "Edit from Here" rewinds the conversation through
/// `revert.stage files:false` + `revert.commit` while restoring the files from the checkpoint. HOME and XDG in a fresh
/// temporary directory; the project is a throwaway repository.
@Suite(
    "Git parity real binary", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["BELLOCODE_GIT_REAL"] == "1" && EngineRepo.vendoredOpencode != nil,
        "set BELLOCODE_GIT_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(10)))
@MainActor
struct GitParityRealBinaryTests {
    @Test func checkpointGenerationAndRewindOnTheRealServer() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let repo = try await TempRepo.make(files: ["README.md": "# Rocket\n"])
        defer { repo.remove() }
        let supervisor = ServerSupervisor(
            configuration: ServerConfiguration(
                executableURL: executable, dataRoot: repo.base.appending(path: "server", directoryHint: .isDirectory),
                expectedVersion: EngineRepo.pinnedVersion, pluginDirectory: OrchestrationRealBinaryTests.pluginDirectory))
        var configuration = EngineConfiguration(server: .supervised(supervisor), store: .inMemory)
        configuration.defaultDirectory = repo.path
        configuration.secretVault = InMemorySecretVault()
        configuration.forgeTokens = InMemorySecretVault()
        let engine = try Engine(configuration: configuration)
        await engine.start()
        defer { Task { await engine.stop() } }
        await engine.addProject(directory: repo.path)
        try await waitUntil("live", timeout: .seconds(30)) { engine.root.connection == .live }
        let thread = try await engine.createThread(in: repo.path, title: "git parity")
        // Run 1: a short turn (no tools needed). The checkpoint is captured before it starts.
        let message = try await engine.send("Reply with the single word OK.", to: thread.id)
        let ref = GitCheckpoints.ref(session: thread.id, message: message)
        #expect(await GitCheckpoints.resolve(ref, directory: repo.path, runner: repo.runner) != nil, "checkpoint before the turn")
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(180)
        while await engine.core.knownSession(thread.id)?.isRunning ?? true, clock.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
        // Runs 2 and 3: generated commit message and branch name.
        try repo.write("CHECKLIST.md", "# Launch checklist\n- [ ] Fuel\n")
        let context = try await repo.repository.commitContext()
        let commitReply = try await engine.generateText(in: thread.id, prompt: GitTextGeneration.commitPrompt(stat: context.stat, patch: context.patch, recentSubjects: ["initial"]))
        let commit = GitTextGeneration.commitMessage(from: commitReply)
        #expect(context.stat.contains("CHECKLIST.md"), "untracked files are part of the context")
        print("git real: commit reply (\(commitReply.count) chars): \(commitReply.prefix(200))")
        print("git real: commit message proposal: \(commit ?? "nil")")
        #expect(commit != nil)
        if ProcessInfo.processInfo.environment["BELLOCODE_GIT_REAL_BRANCH"] == "1" {
            let branchReply = try await engine.generateText(in: thread.id, prompt: GitTextGeneration.branchPrompt(firstPrompt: "Add a launch checklist to the docs", prefix: "bellocode/"))
            let branch = GitTextGeneration.branchName(from: branchReply, prefix: "bellocode/")
            print("git real: branch proposal: \(branch ?? "nil")")
            #expect(branch.map(GitTextGeneration.isValidBranchName) == true)
        }
        // Edit from here with files: CHECKLIST.md goes (it did not exist before the message), the conversation rewinds.
        let plan = try await engine.planRewind(thread.id, to: message, directory: repo.path, revertFiles: true)
        #expect(plan.files?.paths == ["CHECKLIST.md"], "\(String(describing: plan.filesUnavailable))")
        let applied = try await engine.rewind(plan)
        #expect(!FileManager.default.fileExists(atPath: repo.path + "/CHECKLIST.md"))
        let client = try await engine.core.currentClient()
        let remaining = try await client.messages(sessionID: thread.id.rawValue, MessageListQuery(limit: 50)).data
        #expect(!remaining.contains { String(describing: $0).contains(message.rawValue) }, "the message and its reply are gone")
        try await engine.undoRewindFiles(applied)
        #expect(try repo.read("CHECKLIST.md").contains("Fuel"))
    }
}
