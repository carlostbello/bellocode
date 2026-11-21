import Foundation
import Synchronization
import Testing
@testable import Engine
@testable import OpenCodeKit

/// Trust changes are reported as done only when the plugin acknowledged them (A10, N14), and the inventory never turns
/// a failed plugin listing into "BelloCode's plugin is off" (N14) or a sibling folder into the global one (N33).
@Suite("opencode trust acknowledgement", .timeLimit(.minutes(3)))
@MainActor
struct OpenCodeTrustAckTests {
    /// opencode's listing endpoints and the plugin's `bellocode.projectConfig` RPC, scripted.
    final class Transport: HTTPTransport {
        struct State {
            var applied = true
            var failures: [String] = []
            /// Echo the trust file's revision (false: report an older one).
            var echoRevision = true
            var pluginsFail = false
            var skillPath = ""
            var reloads = 0
        }
        let state = Mutex(State())
        let trustFile: URL
        init(trustFile: URL) { self.trustFile = trustFile }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let state = self.state.withLock { $0 }
            var status = 200
            let location = #""location":{"directory":"/r/a"}"#
            var body = #"{\#(location),"data":[]}"#
            switch path {
            case "/api/config": body = "[]"
            case "/api/skill": body = #"{\#(location),"data":[{"id":"s","name":"s","path":"\#(state.skillPath)"}]}"#
            case "/api/plugin":
                if state.pluginsFail { status = 503; body = #"{"_tag":"Unavailable","message":"busy"}"# }
                else { body = #"{\#(location),"data":[{"id":"bellocode","source":{"type":"local"},"state":{"status":"active"}}]}"# }
            case "/api/rpc/bellocode/projectConfig":
                let revision = state.echoRevision ? ProjectTrustFile.read(from: trustFile).revision : 1
                self.state.withLock { $0.reloads += 1 }
                let failures = state.failures.map { "\"\($0)\"" }.joined(separator: ",")
                body = #"{"output":{"mode":"bellocode","revision":\#(revision),"applied":\#(state.applied),"failures":[\#(failures)],"trusted":false,"agents":[],"commands":[],"skills":[],"skipped":[]}}"#
            default: break
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        }
    }

    final class Flag: Sendable {
        let value = Mutex(false)
        var on: Bool { value.withLock { $0 } }
        func set(_ on: Bool) { value.withLock { $0 = on } }
    }

    struct WriteFailure: Error, LocalizedError { var errorDescription: String? { "disk full" } }

    func make(_ root: URL, failWrites: Flag? = nil) async throws -> (OpenCodeConfigService, Transport, OpenCodeDirectories) {
        let directories = OpenCodeDirectories(dataRoot: root)
        let transport = Transport(trustFile: directories.trustFile)
        let connection = ServerConnection(baseURL: URL(string: "http://127.0.0.1:1")!, credentials: ServerCredentials(password: "x"))
        let store = try ProjectionStore(location: .inMemory)
        try await store.setOpenCodeTrust(directory: "/r/a", trusted: true)
        let service = OpenCodeConfigService(
            store: store, directories: directories, runningPolicy: .bellocode,
            client: { OpenCodeClient(connection: connection, transport: transport) }, restartServer: nil,
            writeTrust: { value, file in
                if failWrites?.on == true { throw WriteFailure() }
                try value.write(to: file)
            })
        await service.load()
        return (service, transport, directories)
    }

    @Test func revocationIsDoneOnlyWhenThePluginAcknowledgesTheRevision() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, transport, directories) = try await make(root)
        #expect(await service.setTrusted("/r/a", false) == nil)
        #expect(!service.trustPending)
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted.isEmpty)

        transport.state.withLock { $0.echoRevision = false }
        let stale = await service.setTrusted("/r/a", true)
        #expect(stale?.contains("older trust list") == true)
        #expect(service.trustPending)
        // Retried at the next refresh; acknowledged now.
        transport.state.withLock { $0.echoRevision = true }
        await service.refresh(directory: "/r/a")
        #expect(!service.trustPending)
    }

    @Test func aRejectedTransformReloadIsReported() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, transport, _) = try await make(root)
        transport.state.withLock { $0.applied = false; $0.failures = ["commands"] }
        let problem = await service.setTrusted("/r/a", false)
        #expect(problem?.contains("commands") == true)
        #expect(service.trustPending)
    }

    @Test func aTrustFileWriteFailureIsReportedAndFailsClosed() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = Flag()
        let (service, _, directories) = try await make(root, failWrites: failing)
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted == ["/r/a"])
        #expect(await service.setTrusted("/r/b", true) == nil)
        failing.set(true)
        let problem = await service.setTrusted("/r/a", false)
        #expect(problem?.contains("disk full") == true)
        #expect(service.trustProblem != nil)
        #expect(service.trustPending)
        // The stale list (still trusting /r/a) is gone: the plugin trusts nothing.
        #expect(!FileManager.default.fileExists(atPath: directories.trustFile.path))
        failing.set(false)
        await service.refresh(directory: "/r/a")
        #expect(service.trustProblem == nil)
        #expect(!service.trustPending)
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted == ["/r/b"])
    }

    @Test func concurrentTogglesApplyInOrder() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, _, directories) = try await make(root)
        async let first = service.setTrusted("/r/b", true)
        async let second = service.setTrusted("/r/a", false)
        async let third = service.setTrusted("/r/b", false)
        _ = await (first, second, third)
        #expect(service.trusted.isEmpty)
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted.isEmpty)
    }

    @Test func aFailedPluginListingIsStaleNotPluginOff() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, transport, _) = try await make(root)
        await service.refresh(directory: "/r/a")
        #expect(service.inventory?.pluginProblem == nil, "\(service.inventory?.pluginProblem ?? "")")
        transport.state.withLock { $0.pluginsFail = true }
        await service.refresh(directory: "/r/a")
        #expect(service.refreshError != nil)
        #expect(service.inventory?.pluginProblem == nil)
    }

    @Test func aSiblingOfTheGlobalFolderIsNotGlobal() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, transport, directories) = try await make(root)
        let sibling = directories.globalConfigFolder.standardizedFileURL.path + "-extra/skills/s/SKILL.md"
        transport.state.withLock { $0.skillPath = sibling }
        await service.refresh(directory: "/r/a")
        #expect(service.inventory?.skills.first?.source == OpenCodeItemSource.other)
        transport.state.withLock { $0.skillPath = directories.globalConfigFolder.appending(path: "skills/s/SKILL.md").path }
        await service.refresh(directory: "/r/a")
        #expect(service.inventory?.skills.first?.source == OpenCodeItemSource.global)
    }
}

