import Foundation
import MockOpenCode
import Testing
@testable import OpenCodeKit

/// M2-C client calls: decoding of payloads recorded from the real 2.3.0 server, and round trips against MockOpenCode.
@Suite("OpenCodeClient VCS, worktrees, turn diffs and revert")
struct VCSClientTests {
    private let connection = ServerConnection(baseURL: URL(string: "http://127.0.0.1:4096")!, credentials: ServerCredentials(password: "pw"))

    @Test func decodesRecordedPayloads() async throws {
        let transport = FakeTransport([
            .init(status: 200, body: #"{"location":{"directory":"/r"},"data":{"branch":{}}}"#),
            .init(status: 200, body: #"{"location":{"directory":"/r"},"data":{"name":"main","ref":"refs/heads/main","source":"reflog"}}"#),
            .init(status: 200, body: #"{"location":{"directory":"/r"},"data":[{"file":"f.txt","additions":1,"deletions":0,"status":"modified"},{"file":"u.txt","additions":1,"deletions":0,"status":"added"}]}"#),
            .init(status: 200, body: #"{"data":[{"file":"f.txt","patch":"diff --git a/f.txt b/f.txt\nindex 80e96c1..1cf4df5 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n changed\n+done\n","additions":2,"deletions":1,"status":"modified"}]}"#),
            .init(status: 200, body: #"{"data":{"messageID":"msg_1","snapshot":"8902","files":[]}}"#),
            .init(status: 400, body: #"{"_tag":"WorktreeError","name":"WorktreeError","data":{"message":"fatal: '/w' contains modified or untracked files, use --force to delete it","forceRequired":true}}"#)])
        let client = OpenCodeClient(connection: connection, transport: transport)
        let info = try await client.vcsInfo(directory: "/r")
        #expect(info.branch.current == nil)
        #expect(try await client.vcsBase(directory: "/r")?.source == "reflog")
        let status = try await client.vcsStatus(directory: "/r")
        #expect(status.map(\.status) == [.modified, .added])
        let diff = try await client.sessionDiff(sessionID: "ses_1", from: "msg_1")
        #expect(diff.first?.additions == 2)
        #expect(transport.requests[3].url?.query() == "from=msg_1")
        let revert = try await client.stageRevert(sessionID: "ses_1", messageID: "msg_1", files: false)
        #expect(revert.files == [])
        #expect(String(decoding: transport.requests[4].httpBody ?? Data(), as: UTF8.self) == #"{"files":false,"messageID":"msg_1"}"#)
        do {
            try await client.removeWorktree(projectID: "p", directory: "/w", force: false)
            Issue.record("expected a WorktreeError")
        } catch let error as OpenCodeError {
            #expect(error.worktreeError?.forceRequired == true)
        }
    }

    @Test func roundTripsAgainstTheMock() async throws {
        let server = MockOpenCodeServer(scenario: .empty(directory: "/tmp/vcs-project"), options: .testing)
        let endpoint = try await server.start()
        defer { Task { await server.stop() } }
        await server.setRepository(.sample, for: "/tmp/vcs-project")
        let client = OpenCodeClient(
            connection: ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? "")))
        let info = try await client.vcsInfo(directory: "/tmp/vcs-project/Sources")
        #expect(info.branch.current == "feature/login")
        #expect(try await client.vcsBranches(directory: "/tmp/vcs-project", search: "rel") == ["release/1.2"])
        let working = try await client.vcsDiff(directory: "/tmp/vcs-project", mode: .working)
        #expect(working.map(\.file) == ["Sources/App/Login.swift", "README.md"])
        #expect(working[0].additions == 3 && working[0].deletions == 2)

        let projectID = try #require(try await client.projects().first?.id)
        let session = try await client.createSession(SessionCreateRequest(directory: "/tmp/vcs-project", title: "t"))
        await server.setTurnDiff(sessionID: session.id, from: "msg_turn", files: [working[0].json])
        #expect(try await client.sessionDiff(sessionID: session.id, from: "msg_turn").count == 1)
        let staged = try await client.stageRevert(sessionID: session.id, messageID: "msg_turn", files: true)
        #expect(staged.files?.first?.additions == 2, "inverse patch")
        try await client.clearRevert(sessionID: session.id)
        #expect(await server.stagedRevert(sessionID: session.id) == nil)

        let created = try await client.createWorktree(WorktreeCreateRequest(projectID: projectID, name: "x"))
        #expect(try await client.worktrees(projectID: projectID).map(\.directory) == [created.directory, "/tmp/vcs-project"])
        await server.addWorktree(created.directory, projectID: projectID, dirty: true)
        await #expect(throws: OpenCodeError.self) { try await client.removeWorktree(projectID: projectID, directory: created.directory, force: false) }
        try await client.removeWorktree(projectID: projectID, directory: created.directory, force: true)
        try await client.refreshWorktrees(projectID: projectID)
        // A session in a worktree belongs to the worktree's project.
        await server.addWorktree("/tmp/elsewhere/wt", projectID: projectID)
        let inWorktree = try await client.createSession(SessionCreateRequest(directory: "/tmp/elsewhere/wt", title: "w"))
        #expect(inWorktree.projectID == projectID)
    }
}

extension FileDiffInfo {
    var json: MockOpenCode.JSONValue {
        ["file": .string(file), "patch": .string(patch), "additions": .int(additions), "deletions": .int(deletions), "status": .string(status.rawValue)]
    }
}
