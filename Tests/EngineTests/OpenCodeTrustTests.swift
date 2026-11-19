import Foundation
import GRDB
import Testing
@testable import Engine
@testable import OpenCodeKit

/// Per-project trust of repository opencode configuration (migration `v14-opencode-trust`,
/// docs/features/opencode-config.md): store round trip, migration from v13, and the service's trust file.
@Suite("opencode trust", .timeLimit(.minutes(3)))
@MainActor
struct OpenCodeTrustTests {
    @Test func migrationFromV13AddsAnEmptyTrustTableAndKeepsData() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "projection.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try ProjectionSchema.migrator.migrate(queue, upTo: "v13-shared-browser")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO app_browser_label (project, label) VALUES ('/r/a', 'a')")
        }
        try queue.close()
        let store = try ProjectionStore(location: .file(url))
        #expect(try await store.appliedMigrations().contains("v14-opencode-trust"))
        #expect(try await store.openCodeTrust().isEmpty)
        #expect(try await store.browserLabels() == ["/r/a": "a"])
    }

    @Test func trustRoundTripsAndSurvivesReopenAndRebuild() async throws {
        let directory = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "projection.sqlite")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let store = try ProjectionStore(location: .file(url))
            try await store.setOpenCodeTrust(directory: "/r/a", trusted: true, at: when)
            try await store.setOpenCodeTrust(directory: "/r/b", trusted: true, at: when)
            try await store.setOpenCodeTrust(directory: "/r/b", trusted: false)
            try await store.rebuild()
        }
        let reopened = try ProjectionStore(location: .file(url))
        #expect(try await reopened.openCodeTrust() == ["/r/a": when])
    }

    @Test func serviceMirrorsTrustToThePluginFileAndReportsAnOfflineServer() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ProjectionStore(location: .inMemory)
        try await store.setOpenCodeTrust(directory: "/r/kept", trusted: true)
        let directories = OpenCodeDirectories(dataRoot: root)
        let service = OpenCodeConfigService(
            store: store, directories: directories, runningPolicy: .bellocode,
            client: { throw EngineError.offline }, restartServer: nil)
        await service.load()
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted == ["/r/kept"])

        #expect(await service.setTrusted("/r/new", true) == nil)
        #expect(service.isTrusted("/r/new"))
        #expect(service.trustPending)  // saved, applied when the server is back
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted == ["/r/kept", "/r/new"])
        #expect(try await store.openCodeTrust().keys.sorted() == ["/r/kept", "/r/new"])
        #expect(service.refreshError != nil)

        await service.setTrusted("/r/kept", false)
        #expect(ProjectTrustFile.read(from: directories.trustFile).trusted == ["/r/new"])
        // Without a supervised server there is nothing to restart.
        #expect(await service.restart(policy: .native, directory: nil) != nil)
    }

    @Test func globalFilesAreCreatedFromTemplatesThroughTheService() async throws {
        let root = Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OpenCodeConfigService(
            store: try ProjectionStore(location: .inMemory), directories: OpenCodeDirectories(dataRoot: root), runningPolicy: .bellocode,
            client: { throw EngineError.offline }, restartServer: nil)
        let agents = try await service.ensure(.instructions)
        #expect(agents.path.hasSuffix("config/opencode/AGENTS.md"))
        #expect(FileManager.default.fileExists(atPath: agents.path))
        let skills = try await service.ensure(.skills)
        #expect(skills.path.hasSuffix("config/opencode/skills"))
        // A broken opencode.json is reported with its position, not swallowed.
        try Data("{ \"agents\": ".utf8).write(to: try await service.ensure(.config))
        await service.refresh(directory: nil)
        #expect(service.configProblem?.hasPrefix("opencode.json") == true)
    }
}
