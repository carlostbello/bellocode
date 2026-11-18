import BelloCore
import ContainerKit
import Foundation
import Synchronization
import Testing

@testable import Engine

/// S4 (docs/reviews/deep-review-1.md): helper-config writes are serialised and generation-numbered, success is
/// recorded only after the write, failures are published and retried, and `bellocode-exec` refuses a configuration
/// that is older than the app requires (or from another launch).
@MainActor
@Suite("Helper configuration writer", .serialized, .timeLimit(.minutes(3)))
struct HelperConfigWriterTests {
    /// A file sink that records writes, can hold the configuration write at a gate and can fail on demand.
    final class Sink: Sendable {
        struct State: Sendable {
            var writes: [(file: String, generation: Int)] = []
            var failConfig = false
            var failRequirement = false
            var holdNextConfig = false
            var held: CheckedContinuation<Void, Never>?
            var heldArrived: CheckedContinuation<Void, Never>?
            var isHolding = false
        }
        let state = Mutex(State())

        func write(_ data: Data, _ url: URL) async throws {
            let isRequirement = url.pathExtension == "required"
            let generation: Int = isRequirement
                ? ((try? JSONDecoder().decode(ExecHelperConfig.Requirement.self, from: data))?.generation ?? -1)
                : ((try? JSONDecoder().decode(ExecHelperConfig.self, from: data))?.generation ?? -1)
            if !isRequirement {
                let hold = state.withLock { s -> Bool in
                    defer { s.holdNextConfig = false }
                    return s.holdNextConfig
                }
                if hold {
                    await withCheckedContinuation { continuation in
                        let arrived = state.withLock { s -> CheckedContinuation<Void, Never>? in
                            s.held = continuation
                            s.isHolding = true
                            defer { s.heldArrived = nil }
                            return s.heldArrived
                        }
                        arrived?.resume()
                    }
                }
            }
            let fail = state.withLock { isRequirement ? $0.failRequirement : $0.failConfig }
            if fail { throw CocoaError(.fileWriteNoPermission) }
            try ExecHelperConfig.writeAtomically(data, to: url)
            state.withLock { $0.writes.append((isRequirement ? "required" : "config", generation)) }
        }

        /// Waits until a configuration write is held at the gate.
        func waitUntilHolding() async {
            await withCheckedContinuation { continuation in
                let already = state.withLock { s -> Bool in
                    if s.isHolding { return true }
                    s.heldArrived = continuation
                    return false
                }
                if already { continuation.resume() }
            }
        }

        func release() {
            let held = state.withLock { s -> CheckedContinuation<Void, Never>? in
                defer { s.held = nil; s.isHolding = false }
                return s.held
            }
            held?.resume()
        }
    }

    let root: URL
    let project: String
    let runtime = FakeWorkspaceRuntime()
    let sink = Sink()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bellocode-s4-\(UUID().uuidString)", directoryHint: .isDirectory)
        project = root.appending(path: "project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        runtime.state.withLock { $0.images = ["img:1", "img:2"] }
    }

    var configURL: URL { root.appending(path: "bellocode-exec.json") }

    func makeService() async throws -> EnvironmentService {
        let service = EnvironmentService(
            configuration: ContainerConfiguration(
                helperURL: URL(filePath: "/Applications/BelloCode.app/Contents/Helpers/bellocode-exec"), execConfigURL: configURL,
                opencodeDataDirectory: nil, runtime: runtime, registryVault: InMemorySecretVault()),
            store: try ProjectionStore(location: .inMemory))
        service.worktreeParent = { [root] directory in root.appending(path: "worktrees/\((directory as NSString).lastPathComponent)").path }
        let sink = self.sink
        service.fileSink = { data, url in try await sink.write(data, url) }
        service.configRetryDelay = .milliseconds(10)
        await service.start()
        await service.writeConfigNow()
        return service
    }

    func onDisk() throws -> (config: ExecHelperConfig?, requirement: ExecHelperConfig.Requirement?) {
        let config = FileManager.default.contents(atPath: configURL.path).flatMap { try? JSONDecoder().decode(ExecHelperConfig.self, from: $0) }
        let requirement = FileManager.default.contents(atPath: ExecHelperConfig.Requirement.url(forConfig: configURL).path)
            .flatMap { try? JSONDecoder().decode(ExecHelperConfig.Requirement.self, from: $0) }
        return (config, requirement)
    }

    @Test func writesAreSerialisedInGenerationOrderAndTheNewestStateWins() async throws {
        let service = try await makeService()
        defer { service.stop() }
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        // Hold the first configuration write; while it is held, change the policy again.
        sink.state.withLock { $0.holdNextConfig = true }
        await service.update(project, settings: settings)
        let first = Task { await service.writeConfigNow() }
        await sink.waitUntilHolding()
        settings.network = .none
        await service.update(project, settings: settings)
        let second = Task { await service.writeConfigNow() }
        sink.release()
        await first.value
        await second.value
        let writes = sink.state.withLock { $0.writes }
        let generations = writes.map(\.generation)
        #expect(generations == generations.sorted(), "files land in generation order: \(writes)")
        for index in stride(from: 0, to: writes.count - 1, by: 2) {
            #expect(writes[index].file == "required" && writes[index + 1].file == "config", "the requirement precedes its configuration")
        }
        let (config, requirement) = try onDisk()
        let installed = try #require(config)
        #expect(installed.refusal(requirement: requirement) == nil)
        #expect(installed.workspace(for: project)?.spec?.network == WorkspaceSpec.Network.none, "the newest policy is the one installed")
        #expect(installed.generation == service.installedGeneration)
    }

    @Test func aFailedConfigurationWriteIsPublishedRefusedByTheHelperAndRetried() async throws {
        let service = try await makeService()
        defer { service.stop() }
        let before = service.installedGeneration
        sink.state.withLock { $0.failConfig = true }
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:1"
        settings.network = .none
        await service.update(project, settings: settings)
        await service.writeConfigNow()
        #expect(service.helperConfigProblem != nil, "the failure is visible")
        #expect(service.installedGeneration == before, "success is not recorded for a failed write")
        let (stale, requirement) = try onDisk()
        #expect(try #require(stale).refusal(requirement: requirement) != nil, "the older file on disk no longer authorises commands")
        // The store recovers: the retry installs the current policy and clears the problem.
        sink.state.withLock { $0.failConfig = false }
        try await waitUntil("retried") { service.helperConfigProblem == nil }
        let (config, current) = try onDisk()
        #expect(try #require(config).refusal(requirement: current) == nil)
        #expect(config?.workspace(for: project)?.spec?.network == WorkspaceSpec.Network.none)
    }

    @Test func aFailedRequirementWriteRemovesTheConfiguration() async throws {
        let service = try await makeService()
        defer { service.stop() }
        #expect(FileManager.default.fileExists(atPath: configURL.path))
        sink.state.withLock { $0.failRequirement = true }
        var settings = ProjectEnvironmentSettings()
        settings.image = "img:2"
        await service.update(project, settings: settings)
        await service.writeConfigNow()
        #expect(service.helperConfigProblem != nil)
        #expect(!FileManager.default.fileExists(atPath: configURL.path), "no configuration is left to authorise an older policy")
        sink.state.withLock { $0.failRequirement = false }
        try await waitUntil("retried") { service.helperConfigProblem == nil }
        #expect(FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test func anotherLaunchesConfigurationNeverAuthorises() async throws {
        let first = try await makeService()
        first.stop()
        let (old, _) = try onDisk()
        let second = try await makeService()
        defer { second.stop() }
        let (_, requirement) = try onDisk()
        #expect(try #require(old).refusal(requirement: requirement) != nil, "a file from an earlier launch is refused")
    }
}

@Suite("bellocode-exec authorisation", .timeLimit(.minutes(3)))
struct HelperAuthorisationTests {
    @Test func refusalRules() {
        let config = ExecHelperConfig(socket: "/s", workspaces: [], epoch: "a", generation: 3)
        #expect(config.refusal(requirement: nil) != nil)
        #expect(config.refusal(requirement: .init(epoch: "b", generation: 1)) != nil)
        #expect(config.refusal(requirement: .init(epoch: "a", generation: 4)) != nil)
        #expect(config.refusal(requirement: .init(epoch: "a", generation: 3)) == nil)
        #expect(ExecHelperConfig(socket: "/s", workspaces: []).refusal(requirement: .init(epoch: "a", generation: 0)) != nil)
    }

    /// The real helper refuses (exit 125, nothing run, no Docker contact) when the installed configuration is older
    /// than the requirement.
    @Test func theHelperRefusesAnOlderConfiguration() async throws {
        let helper = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-s4h-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "p").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let url = root.appending(path: "bellocode-exec.json")
        try ExecHelperConfig(socket: root.appending(path: "no.sock").path, workspaces: [.init(roots: [project], container: "c")],
                             epoch: "e", generation: 1).write(to: url)
        try ExecHelperConfig.writeAtomically(try ExecHelperConfig.Requirement(epoch: "e", generation: 2).encoded(),
                                             to: ExecHelperConfig.Requirement.url(forConfig: url))
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        process.executableURL = URL(filePath: helper)
        process.arguments = ["-c", "touch \(root.path)/ran"]
        process.currentDirectoryURL = URL(filePath: project)
        process.environment = ["BELLOCODE_EXEC_CONFIG": url.path, "PATH": "/usr/bin:/bin"]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 125)
        #expect(String(decoding: output, as: UTF8.self).contains("not finished saving the current command policy"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "ran").path))
    }
}
