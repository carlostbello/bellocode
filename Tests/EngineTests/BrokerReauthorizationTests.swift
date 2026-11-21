import BelloCore
import Foundation
import Network
import OpenCodeKit
import Synchronization
import Testing

@testable import Engine
@testable import SecretKit

/// A loopback HTTPS server (`localhost`) whose `/v1/start` answers a redirect to `/v1/next` only once `open()` is
/// called; every request head is recorded.
final class GatedRedirectServer: Sendable {
    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let state = Mutex<(paths: [String], open: Bool, waiters: [CheckedContinuation<Void, Never>])>(([], false, []))
    private let tasks = Mutex<[Task<Void, Never>]>([])

    var paths: [String] { state.withLock { $0.paths } }

    init(authority: CertificateAuthority) async throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(try authority.identity(for: "localhost"))!)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "gated-redirect-server", attributes: .concurrent)
        self.queue = queue
        let box = Mutex<GatedRedirectServer?>(nil)
        let resumed = Mutex(false)
        listener.newConnectionHandler = { connection in box.withLock { $0 }?.accept(connection) }
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.withLock({ was in defer { was = true }; return !was }) { continuation.resume(returning: listener.port!.rawValue) }
                case .failed(let error): if resumed.withLock({ was in defer { was = true }; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        box.withLock { $0 = self }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func stop() {
        open()
        listener.cancel()
        tasks.withLock { $0.forEach { $0.cancel() } }
    }

    private func waitForOpen() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if ready { continuation.resume() }
        }
    }

    private func accept(_ connection: NWConnection) {
        let task = Task { [self] in
            let wire = WireConnection(connection, queue: queue)
            do {
                try await wire.start()
                while let data = try await wire.readHead(), let head = HTTPHead(data) {
                    _ = try await wire.readBody(head.requestFraming() ?? .empty, limit: 1 << 20)
                    let path = head.startLine[1]
                    state.withLock { $0.paths.append(path) }
                    if path.hasPrefix("/v1/start") {
                        await waitForOpen()
                        try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "302", "Found"], fields: [
                            HTTPField("Location", "https://localhost:\(port)/v1/next"), HTTPField("Content-Length", "0"),
                        ]).serialized)
                    } else {
                        try await wire.send(HTTPHead(startLine: ["HTTP/1.1", "200", "OK"], fields: [HTTPField("Content-Length", "2")]).serialized + Data("ok".utf8))
                    }
                }
            } catch {}
            wire.cancel()
        }
        tasks.withLock { $0.append(task) }
    }
}

/// v1.0.0 review A12: each outbound hop of the brokered tool is re-authorized against the secret as it is now. A
/// revocation (or a change of scope, mode, bindings or value) while the first hop waits stops the redirect's request.
@MainActor
@Suite("Broker re-authorization", .serialized, .timeLimit(.minutes(2)))
struct BrokerReauthorizationTests {
    static let value = "sk_live_REAUTH_0123456789abcdef"

    func run(change: (SecretManager, ManagedSecret) async throws -> Void) async throws -> (ClientMCPResult, [String]) {
        let ca = try CertificateAuthority(commonName: "Broker reauthorization CA")
        let server = try await GatedRedirectServer(authority: ca)
        defer { server.stop() }
        let f = try await SecretValuePolicyBindingTests.Light.make()
        f.manager.extraBrokerAnchors = [ca.certificateDER]
        let binding = SecretBinding(host: "localhost", port: Int(server.port), pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])
        let secret = try await f.manager.create(label: "Reauth key", value: SecretValue(Self.value), mode: .brokered, bindings: [binding])
        let caller = ExtrasCaller(sessionID: SessionID("ses_reauth"), projectID: ProjectID("p"), directory: "/p", projectDirectory: "/p")
        let arguments: OpenCodeKit.JSONValue = .object([
            "url": .string("https://localhost:\(server.port)/v1/start"),
            "headers": .object(["Authorization": .string("Bearer {{secret:\(secret.name)}}")]),
        ])
        let call = Task { @MainActor in await f.manager.httpRequest(arguments, caller: caller) }
        try await waitUntil("first hop received") { server.paths.contains { $0.hasPrefix("/v1/start") } }
        try await change(f.manager, secret)
        server.open()
        let result = await call.value
        return (result, server.paths)
    }

    @Test func aRevocationDuringTheFirstHopStopsTheRedirect() async throws {
        let (result, paths) = try await run { manager, secret in try await manager.revoke(account: secret.account) }
        #expect(!paths.contains("/v1/next"), "the redirect was followed with a revoked secret: \(paths)")
        #expect(result.isError, "\(result.text)")
    }

    @Test func aNarrowedScopeOrBindingDuringTheFirstHopStopsTheRedirect() async throws {
        let (scoped, scopedPaths) = try await run { manager, secret in
            var next = secret
            next.scope = .project("/elsewhere")
            try await manager.update(next)
        }
        #expect(!scopedPaths.contains("/v1/next"), "\(scopedPaths)")
        #expect(scoped.isError)
        let (rebound, reboundPaths) = try await run { manager, secret in
            var next = secret
            next.bindings = [SecretBinding(host: "api.example.com", pathPrefixes: ["/v1"], locations: [.header("Authorization", prefix: "Bearer ")])]
            try await manager.update(next)
        }
        #expect(!reboundPaths.contains("/v1/next"), "\(reboundPaths)")
        #expect(rebound.isError)
    }

    @Test func anUnchangedSecretStillFollowsTheRedirect() async throws {
        let (result, paths) = try await run { _, _ in }
        #expect(paths.contains("/v1/next"), "\(paths)")
        #expect(result.text.hasPrefix("Status: 200"), "\(result.text)")
    }
}
