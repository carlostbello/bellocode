import BelloCore
import Darwin
import Foundation
import OpenCodeKit
import Testing

@testable import Engine

/// Deep review 1, C1: the plugin confirms a delegated child's worktree by comparing the session's reported
/// `location.directory` with the directory `worktree.create` returned. This checks, on the pinned binary and without a
/// model prompt, that a moved session reports exactly that string (no symlink or trailing-slash difference) and that a
/// fresh session in the main checkout does not. HOME/XDG live in a temporary directory; the server is stopped before
/// the test returns.
@MainActor
@Suite("Worktree move real binary", .serialized, .enabled(if: EngineRepo.vendoredOpencode != nil, "run Scripts/fetch-opencode.sh"), .timeLimit(.minutes(10)))
struct WorktreeMoveRealBinaryTests {
    @Test func aMovedSessionReportsTheWorktreeDirectoryVerbatim() async throws {
        let executable = try #require(EngineRepo.vendoredOpencode)
        let repo = try await TempRepo.make("project", files: ["f.txt": "a\n"])
        defer { repo.remove() }
        let configuration = ServerConfiguration(
            executableURL: executable, dataRoot: repo.base.appending(path: "server", directoryHint: .isDirectory),
            expectedVersion: EngineRepo.pinnedVersion)
        let supervisor = ServerSupervisor(configuration: configuration)
        await supervisor.start()
        var endpoint = await supervisor.endpoint
        let deadline = ContinuousClock.now + .seconds(30)
        while endpoint == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            endpoint = await supervisor.endpoint
        }
        let ready = try #require(endpoint, "server did not become ready")
        let client = OpenCodeClient(endpoint: ready)

        let projectID = try await client.location(directory: repo.path).project.id
        let worktree = try await client.createWorktree(WorktreeCreateRequest(projectID: projectID, name: "child"))
        let session = try await client.createSession(SessionCreateRequest(directory: repo.path, title: "child"))
        #expect(session.location.directory != worktree.directory, "a new session starts in the main checkout")

        var request = URLRequest(url: ready.connection.baseURL.appending(path: "api/session/\(session.id)/move"))
        request.httpMethod = "POST"
        let password = ready.connection.credentials.clientEnvironment["OPENCODE_PASSWORD"] ?? ""
        request.setValue("Basic " + Data("\(ServerCredentials.username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["directory": worktree.directory])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)

        var moved = try await client.session(session.id)
        for _ in 0..<20 where moved.location.directory != worktree.directory {
            try await Task.sleep(for: .milliseconds(50))
            moved = try await client.session(session.id)
        }
        #expect(moved.location.directory == worktree.directory, "the plugin's exact comparison holds on 2.3.0")

        try await client.removeWorktree(projectID: projectID, directory: worktree.directory, force: true)
        let pid = await supervisor.childPID
        await supervisor.stop()
        if let pid { #expect(kill(pid, 0) != 0, "server child \(pid) still running") }
    }
}
