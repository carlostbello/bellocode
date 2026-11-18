import Foundation
import Synchronization
import Testing
@testable import OpenCodeKit

/// The `experimental.browser` bridge against the pinned (or candidate) opencode: attach at `BrowserContract.version`,
/// see `attached`, the granted browser rules, a published state acknowledged, and `closed` when the session is
/// deleted. No model prompt. Isolated XDG/HOME in a temporary directory; the server is stopped before returning.
///
/// Opt-in: `BELLOCODE_CONTRACT_REAL=1 swift test --filter BrowserAttachRealBinary` (part of `make opencode-verify`).
@Suite(
    "Browser attach real binary", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BELLOCODE_CONTRACT_REAL"] == "1" && Repo.vendoredOpencode != nil,
             "set BELLOCODE_CONTRACT_REAL=1 and run Scripts/fetch-opencode.sh"),
    .timeLimit(.minutes(3)))
struct BrowserAttachRealBinaryTests {
    @Test func attachGrantsToolsPublishesStateAndClosesWithTheSession() async throws {
        let executable = try #require(Repo.vendoredOpencode)
        let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-browser-real-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ServerSupervisor(configuration: ServerConfiguration(
            executableURL: executable, dataRoot: root.appending(path: "server", directoryHint: .isDirectory),
            helpersDirectory: Repo.root.appending(path: "Vendor/ripgrep", directoryHint: .isDirectory),
            expectedVersion: Repo.pinnedVersion))
        await supervisor.start()
        let endpoint = try await within(.seconds(30)) { try await supervisor.awaitReady() }
        let client = OpenCodeClient(endpoint: endpoint)
        let hub = EventHub(connector: URLSessionEventStreamConnector { client })
        let subscription = await hub.subscribe(.types([BrowserContract.controlEventType]))
        await hub.start()
        let routes = Routes()
        let pump = Task {
            for await message in subscription {
                guard case .event(let envelope) = message, let control = envelope.browserControl, let id = control.connectionID,
                    let attachment = routes.withLock({ $0[id] })
                else { continue }
                await attachment.receive(control)
            }
        }
        func finish() async {
            pump.cancel()
            await hub.stop()
            await supervisor.stop()
        }
        do {
            try await eventually(timeout: .seconds(15)) {
                if case .connected = await hub.connectionState { return true }
                return false
            }
            let session = try await client.createSession(SessionCreateRequest(directory: project.path, title: "browser attach"))
            // A location activates on first use; until its plugins are up the bridge answers `unavailable` (as the
            // bellocode plugin's RPC does). The app retries; so does this test, for at most ~10 s.
            for _ in 0..<40 where (try? await client.agents(directory: project.path))?.isEmpty ?? true {
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(!(session.permissions ?? []).contains { $0.action == "browser" && $0.effect == .allow })
            let tab = BrowserTabInfo(
                id: "tab_00000000-0000-4000-8000-000000000001", url: "about:blank", title: "Blank", loading: false,
                canGoBack: false, canGoForward: false, generation: 0)
            let inventory = BrowserInventory(tabs: [tab], focusedTabID: tab.id)
            // An ended attachment cannot restart, so each attempt is a new one (as the app's reconnect does).
            var attached: BrowserAttachment?
            for attempt in 1...20 {
                let candidate = BrowserAttachment(
                    sessionID: session.id, directory: project.path, client: { client }, inventory: { inventory },
                    perform: { _ in .failure(BrowserFailure("unsupported", "not used")) }, observer: { _ in })
                routes.withLock { $0[candidate.connectionID] = candidate }
                do {
                    try await candidate.start(readyTimeout: .seconds(20))
                    attached = candidate
                    break
                } catch .unavailable where attempt < 20 {
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            let attachment = try #require(attached)
            #expect(await attachment.isAttached, "the server answered `attached` for version \(BrowserContract.version)")
            await attachment.publishAndWait()
            let granted = try await client.session(session.id).permissions ?? []
            #expect(granted.contains { $0.action == "browser" && $0.resource == "*" && $0.effect == .allow })
            #expect(granted.contains { $0.action == "skill" && $0.resource == "browser" && $0.effect == .allow })

            try await client.deleteSession(session.id)
            try await eventually(timeout: .seconds(10)) { await attachment.end != nil }
            #expect(await attachment.end == .closed, "deleting the session closes the attachment")
        } catch {
            await finish()
            throw error
        }
        await finish()
    }
}

private final class Routes: Sendable {
    private let storage = Mutex<[String: BrowserAttachment]>([:])
    func withLock<R: Sendable>(_ body: (inout [String: BrowserAttachment]) -> R) -> R { storage.withLock { body(&$0) } }
}
