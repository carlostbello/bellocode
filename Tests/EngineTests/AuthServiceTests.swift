import BelloCore
import Foundation
import MockOpenCode
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine

/// Records URLs instead of opening a browser.
final class OpenedURLs: Sendable {
    private let urls = Mutex<[URL]>([])
    var all: [URL] { urls.withLock { $0 } }
    func append(_ url: URL) { urls.withLock { $0.append(url) } }
}

@Suite("AuthService against the mock", .timeLimit(.minutes(3)))
@MainActor
struct AuthServiceTests {
    func makeService(_ harness: MockHarness, opened: OpenedURLs = OpenedURLs(), retries: Int = 5) -> AuthService {
        let client = harness.client
        return AuthService(
            client: { client }, directory: { "/tmp/mock-project" }, openURL: { opened.append($0) },
            pollInterval: .milliseconds(10), emptyListRetries: retries)
    }

    @Test func listsIntegrationsRetryingAColdLocation() async throws {
        let harness = try await MockHarness.start()
        await harness.server.makeIntegrationsCold(calls: 2)
        let service = makeService(harness)
        await service.refresh()
        #expect(service.listState == .loaded)
        #expect(service.integrations.count == MockIntegration.standard.count)
        #expect(service.integrations.first?.id == "opencode")
        let copilot = try #require(service.integration("github-copilot"))
        let oauth = try #require(copilot.methods.first { $0.kind == .oauth })
        #expect(oauth.fields.map(\.key) == ["deploymentType", "enterpriseUrl"])
        #expect(oauth.fields[1].conditions == [QuestionField.Condition(key: "deploymentType", equals: true, value: .text("enterprise"))])
        #expect(copilot.methods.first { $0.kind == .environment }?.isInteractive == false)
        let console = try #require(service.integration("opencode")?.methods.first { $0.kind == .oauth })
        #expect(console.fields.first?.hidden == true)
        #expect(service.search("anth").first?.id == "anthropic")
        #expect(service.search("zzz").isEmpty)
        await harness.stop()
    }

    @Test func keyConnectSucceedsAndFailsWithTheServersReason() async throws {
        let harness = try await MockHarness.start()
        let service = makeService(harness)
        await service.refresh()

        await service.connectKey(integrationID: "anthropic", key: "   ")
        #expect(service.flow?.phase == .failed(message: "Enter an API key."))

        await service.connectKey(integrationID: "azure", key: "sk-test")
        #expect(service.flow?.phase == .failed(message: "Missing required form field: resourceName"))

        await service.connectKey(integrationID: "azure", key: " sk-test ", answers: ["resourceName": .text("r")])
        #expect(service.flow?.phase == .succeeded)
        #expect(await harness.server.credential("azure", hasKey: "sk-test"))
        #expect(service.integration("azure")?.isConnected == true)
        #expect(service.credentials(for: "azure").map(\.isActive) == [true])

        await harness.server.injectHTTPFault(.status(500, method: "POST", pathPrefix: "/api/integration/anthropic"))
        await service.connectKey(integrationID: "anthropic", key: "k")
        guard case .failed = service.flow?.phase else { Issue.record("expected failure"); return }
        await service.connectKey(integrationID: "anthropic", key: "k")
        #expect(service.flow?.phase == .succeeded)
        await harness.stop()
    }

    @Test func oauthAutoPollsUntilComplete() async throws {
        let harness = try await MockHarness.start()
        let opened = OpenedURLs()
        let service = makeService(harness, opened: opened)
        await harness.server.setOAuthBehaviour(.completeAfterPolls(3), integrationID: "openai", methodID: "chatgpt-browser")
        await service.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        guard case .waitingForBrowser(let url, _, let canPaste, _) = service.flow?.phase else {
            Issue.record("expected waitingForBrowser, got \(String(describing: service.flow))")
            return
        }
        #expect(canPaste)
        #expect(opened.all == [url])
        try await waitUntil("complete") { service.flow?.phase == .succeeded }
        #expect(service.integration("openai")?.isConnected == true)
        #expect(service.credentials(for: "openai").first?.kind == "oauth")
        await harness.stop()
    }

    @Test func oauthCodeRejectsThenAccepts() async throws {
        let harness = try await MockHarness.start()
        let service = makeService(harness)
        await harness.server.setOAuthBehaviour(.code("GOOD-1"), integrationID: "gitlab", methodID: "pkce")
        await service.startOAuth(integrationID: "gitlab", methodID: "pkce", answers: ["instanceUrl": .text("https://gitlab.com")])
        guard case .waitingForCode = service.flow?.phase else { Issue.record("expected waitingForCode"); return }
        await service.submitCode("WRONG")
        guard case .waitingForCode(_, _, _, let error) = service.flow?.phase else { Issue.record("expected to stay"); return }
        #expect(error == "The code was not accepted.")
        await service.submitCode(" GOOD-1 ")
        #expect(service.flow?.phase == .succeeded)
        await harness.stop()
    }

    @Test func oauthFailureExpiryAndCancel() async throws {
        let harness = try await MockHarness.start()
        let service = makeService(harness)
        await harness.server.setOAuthBehaviour(.fail("Access denied by the provider"), integrationID: "openai", methodID: "chatgpt-browser")
        await service.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        try await waitUntil("failed") { service.flow?.phase == .failed(message: "Access denied by the provider") }

        await harness.server.setOAuthBehaviour(.expire, integrationID: "openai", methodID: "chatgpt-browser")
        await service.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        try await waitUntil("expired") { service.flow?.phase == .expired }

        await harness.server.setOAuthBehaviour(.pending, integrationID: "openai", methodID: "chatgpt-browser")
        await service.startOAuth(integrationID: "openai", methodID: "chatgpt-browser")
        for _ in 0..<400 where await harness.server.openAttemptCount() != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await harness.server.openAttemptCount() == 1)
        await service.cancel()
        #expect(service.flow?.phase == .cancelled)
        #expect(await harness.server.openAttemptCount() == 0)
        service.clearFlow()
        #expect(service.flow == nil)
        #expect(await harness.server.storedCredentials().isEmpty)
        await harness.stop()
    }

    @Test func commandLoginCompletes() async throws {
        let harness = try await MockHarness.start()
        let service = makeService(harness)
        await service.startCommand(integrationID: "fictional-labs", methodID: "cli")
        try await waitUntil("complete") { service.flow?.phase == .succeeded }
        #expect(service.integration("fictional-labs")?.isConnected == true)
        await harness.stop()
    }

    @Test func credentialsActivateRenameRemoveWithRollback() async throws {
        let harness = try await MockHarness.start()
        let service = makeService(harness)
        await service.connectKey(integrationID: "anthropic", key: "k1")
        await service.connectKey(integrationID: "anthropic", key: "k2", label: "Work")
        let items = service.credentials(for: "anthropic")
        #expect(Set(items.map(\.label)) == ["Anthropic", "Work"])
        let first = try #require(items.first { $0.label == "Anthropic" })
        await service.activate(first.id)
        #expect(service.credentials(for: "anthropic").first { $0.isActive }?.id == first.id)

        await harness.server.injectHTTPFault(.status(500, method: "PATCH", pathPrefix: "/api/credential"))
        await service.rename(first.id, to: "Personal")
        #expect(service.credentials.first { $0.id == first.id }?.label == "Anthropic")
        #expect(service.lastError != nil)
        await service.rename(first.id, to: "Personal")
        #expect(service.credentials.first { $0.id == first.id }?.label == "Personal")

        await service.remove(first.id)
        #expect(service.credentials(for: "anthropic").count == 1)
        #expect(String(describing: service.credentials).contains("k2") == false)
        await harness.stop()
    }

    @Test func importOutputParsing() {
        #expect(CredentialImporter.parse("Imported 2 credentials\n") == CredentialImportResult(imported: 2, skipped: 0))
        #expect(CredentialImporter.parse("Imported 0 credentials, skipped 2 already present") == CredentialImportResult(imported: 0, skipped: 2))
        #expect(CredentialImporter.parse("") == CredentialImportResult(imported: 0, skipped: 0))
    }
}
