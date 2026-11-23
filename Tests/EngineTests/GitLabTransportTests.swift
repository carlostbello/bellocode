import BelloCore
import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine

/// A loopback HTTP/1.1 server answering every request with a fixed response (a redirect, or JSON). Records each
/// request's head (path and whether a PRIVATE-TOKEN header came with it). Plain POSIX sockets on a private queue.
final class RedirectFixtureServer: Sendable {
    struct Seen: Sendable {
        var path: String
        var hadToken: Bool
    }

    let port: UInt16
    private let socket: Int32
    private let seen = Mutex<[Seen]>([])
    private let respond: @Sendable (String) -> String

    init(respond: @escaping @Sendable (_ path: String) -> String) throws {
        self.respond = respond
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        socket = fd
        let server = self
        Thread.detachNewThread { server.acceptLoop() }
    }

    var requests: [Seen] { seen.withLock { $0 } }

    func stop() { shutdown(socket, SHUT_RDWR); close(socket) }

    private func acceptLoop() {
        while true {
            let client = accept(socket, nil, nil)
            if client < 0 { return }
            // The client may hang up before the response is written: EPIPE, not SIGPIPE.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 16 << 10)
            var head = Data()
            while !head.contains(Data("\r\n\r\n".utf8)) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                head.append(contentsOf: buffer[0..<count])
            }
            let text = String(decoding: head, as: UTF8.self)
            let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            seen.withLock { $0.append(Seen(path: path, hadToken: text.lowercased().contains("private-token:"))) }
            let response = respond(path)
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }

    static func redirect(to location: String) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }

    static func json(_ body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

/// M1 and m1 (docs/reviews/M3-M6-review.md): the GitLab token never goes to another origin or over unapproved HTTP;
/// remotes match instances by port.
@Suite(.timeLimit(.minutes(3)))
struct GitLabTransportTests {
    @Test func crossOriginRedirectsAreRefusedBeforeTheTokenTravels() async throws {
        let elsewhere = try RedirectFixtureServer { _ in RedirectFixtureServer.json("{}") }
        defer { elsewhere.stop() }
        let origin = try RedirectFixtureServer { path in
            path.hasPrefix("/same") ? RedirectFixtureServer.json(#"{"username":"me"}"#)
                : path.hasPrefix("/hop") ? RedirectFixtureServer.redirect(to: "/same")
                : RedirectFixtureServer.redirect(to: "http://127.0.0.1:\(elsewhere.port)/api/v4/user")
        }
        defer { origin.stop() }
        let transport = URLSessionForgeTransport()
        let headers = ["PRIVATE-TOKEN": "zz-SENTINEL-token"]
        // Another port on the same host: refused, typed, and nothing reached the other server.
        await #expect(throws: ForgeError.self) {
            _ = try await transport.send(ForgeRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/api/v4/user")!, headers: headers))
        }
        #expect(elsewhere.requests.isEmpty, "the redirect target was never contacted")
        // A same-origin redirect within the request's scope is followed.
        let followed = try await transport.send(ForgeRequest(
            url: URL(string: "http://127.0.0.1:\(origin.port)/hop")!, headers: headers, redirectScope: URL(string: "http://127.0.0.1:\(origin.port)")))
        #expect(followed.status == 200)
        #expect(origin.requests.contains { $0.path == "/same" })
        // Host spelling counts as another origin too (localhost vs 127.0.0.1), as does a scheme change.
        #expect(!URLSessionForgeTransport.sameOrigin(URL(string: "https://h/x")!, URL(string: "http://h/x")!))
        #expect(!URLSessionForgeTransport.sameOrigin(URL(string: "https://h/x")!, URL(string: "https://h:8443/x")!))
        #expect(URLSessionForgeTransport.sameOrigin(URL(string: "https://H:443/x")!, URL(string: "https://h/y")!))
    }

    /// AV04: two applications behind one origin under different path prefixes. The token is the first one's; a redirect
    /// (first hop or a later one) to the other prefix is refused before it is followed, and nothing reaches it. A
    /// redirect within the instance's API base is still followed.
    @Test func redirectsStayUnderTheInstancesAPIBase() async throws {
        let server = try RedirectFixtureServer { path in
            path.hasPrefix("/team-a/api/v4/user") ? RedirectFixtureServer.json(#"{"username":"me"}"#)
                : path.hasPrefix("/team-a/api/v4/moved") ? RedirectFixtureServer.redirect(to: "/team-a/api/v4/user")
                : path.hasPrefix("/team-a/api/v4/hop") ? RedirectFixtureServer.redirect(to: "/team-a/api/v4/away")
                : path.hasPrefix("/team-a/api/v4/away") ? RedirectFixtureServer.redirect(to: "/team-b/api/v4/user")
                : path.hasPrefix("/team-a/api/v4/dots") ? RedirectFixtureServer.redirect(to: "/team-a/api/v4/%2e%2e/%2e%2e/../team-b/api/v4/user")
                : path.hasPrefix("/team-b") ? RedirectFixtureServer.json(#"{"username":"someone else"}"#)
                : RedirectFixtureServer.redirect(to: "/team-b/api/v4/user")
        }
        defer { server.stop() }
        let instance = try #require(GitLabInstance(baseURL: "http://127.0.0.1:\(server.port)/team-a"))
        let vault = InMemorySecretVault()
        try vault.store(account: instance.baseURL, label: "t", value: SecretValue("zz-SENTINEL-token"))
        let transport = URLSessionForgeTransport()
        let scope = URL(string: instance.apiBase)
        let headers = ["PRIVATE-TOKEN": "zz-SENTINEL-token"]
        for path in ["/team-a/api/v4/projects", "/team-a/api/v4/hop", "/team-a/api/v4/dots"] {
            await #expect(throws: ForgeError.self, "\(path)") {
                _ = try await transport.send(ForgeRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!, headers: headers, redirectScope: scope))
            }
        }
        #expect(!server.requests.contains { $0.path.hasPrefix("/team-b") }, "\(server.requests.map(\.path))")
        // Through the provider (which scopes every request to the instance's API base): followed within it.
        let provider = GitLabProvider(transport: transport, tokens: vault, plainHTTPAllowed: { let list = PlainHTTPAllowList(); list.set([instance.baseURL]); return list }())
        let moved = try await transport.send(ForgeRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/team-a/api/v4/moved")!, headers: headers, redirectScope: scope))
        #expect(moved.status == 200)
        #expect(try await provider.currentUser(instance) == "me")
        // A request without a scope follows no redirect at all.
        await #expect(throws: ForgeError.self) {
            _ = try await transport.send(ForgeRequest(url: URL(string: "http://127.0.0.1:\(server.port)/team-a/api/v4/moved")!, headers: headers))
        }
        #expect(!server.requests.contains { $0.path.hasPrefix("/team-b") })
        #expect(URLSessionForgeTransport.within(URL(string: "https://h/a/api/v4")!, URL(string: "https://h/a/api/v4/projects/1")!))
        #expect(!URLSessionForgeTransport.within(URL(string: "https://h/a/api/v4")!, URL(string: "https://h/a/api/v40")!))
        #expect(!URLSessionForgeTransport.within(URL(string: "https://h/a/api/v4")!, URL(string: "https://h/b/api/v4/user")!))
        #expect(!URLSessionForgeTransport.within(URL(string: "https://h/a/api/v4")!, URL(string: "https://h/a/api/v4/%2E%2E/x")!))
        #expect(!URLSessionForgeTransport.within(URL(string: "https://h/a/api/v4")!, URL(string: "https://h/a/api/v4/x%2F..%2F..")!))
    }

    @Test func plainHTTPNeedsAnExplicitPerInstanceChoice() async throws {
        let server = try RedirectFixtureServer { _ in RedirectFixtureServer.json(#"{"username":"me"}"#) }
        defer { server.stop() }
        let instance = try #require(GitLabInstance(baseURL: "http://127.0.0.1:\(server.port)"))
        let vault = InMemorySecretVault()
        try vault.store(account: instance.baseURL, label: "t", value: SecretValue("zz-SENTINEL-token"))
        let allow = PlainHTTPAllowList()
        let provider = GitLabProvider(transport: URLSessionForgeTransport(), tokens: vault, plainHTTPAllowed: allow)
        await #expect(throws: ForgeError.insecureInstance(instance.baseURL)) { _ = try await provider.currentUser(instance) }
        #expect(server.requests.isEmpty, "nothing was sent")
        allow.set([instance.baseURL])
        #expect(try await provider.currentUser(instance) == "me")
        #expect(server.requests.first?.hadToken == true)
    }

    @Test @MainActor func settingsRefuseHTTPWithoutTheChoiceAndRememberIt() async throws {
        let store = try ProjectionStore(location: .inMemory)
        let service = MergeRequestService(
            store: store, clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)), transport: FixtureForgeTransport(),
            tokens: InMemorySecretVault(), autoPoll: false)
        await service.start()
        await #expect(throws: ExtrasError.self) { _ = try await service.saveInstance(baseURL: "http://gitlab.internal", token: nil) }
        let instance = try await service.saveInstance(baseURL: "http://gitlab.internal", token: nil, allowPlainHTTP: true)
        #expect(service.plainHTTPAllowed.contains(instance.baseURL))
        _ = try await service.saveInstance(baseURL: "https://gitlab.example.com", token: nil)
        // Relaunch: the choice is remembered; removing the instance forgets it.
        let again = MergeRequestService(
            store: store, clock: ManualWallClock(Date(timeIntervalSince1970: 1_800_000_000)), transport: FixtureForgeTransport(),
            tokens: InMemorySecretVault(), autoPoll: false)
        await again.start()
        #expect(again.plainHTTPAllowed.all == [instance.baseURL])
        try await again.removeInstance(instance)
        #expect(again.plainHTTPAllowed.all.isEmpty)
        service.shutdown()
        again.shutdown()
    }

    @Test func remotesMatchInstancesByPortAndSSHIsAmbiguousOnASharedHost() throws {
        let main = try #require(GitLabInstance(baseURL: "https://git.example.com"))
        let other = try #require(GitLabInstance(baseURL: "https://git.example.com:8443"))
        let both = [main, other]
        #expect(ForgeProject.resolve(remote: "https://git.example.com:8443/team/app.git", instances: both)?.instance == other)
        #expect(ForgeProject.resolve(remote: "https://git.example.com/team/app.git", instances: both)?.instance == main)
        #expect(ForgeProject.resolve(remote: "https://git.example.com:443/team/app.git", instances: both)?.instance == main)
        #expect(ForgeProject.resolve(remote: "http://git.example.com/team/app.git", instances: both) == nil, "scheme counts")
        #expect(ForgeProject.resolve(remote: "https://git.example.com:9999/team/app.git", instances: both) == nil)
        #expect(ForgeProject.resolve(remote: "git@git.example.com:team/app.git", instances: both) == nil, "two instances on the host: ambiguous")
        #expect(ForgeProject.resolve(remote: "git@git.example.com:team/app.git", instances: [other])?.instance == other)
        #expect(MergeRequestRef.parse("https://git.example.com:8443/team/app/-/merge_requests/7", instances: both)?.instance == other.baseURL)
        #expect(MergeRequestRef.parse("https://git.example.com/team/app/-/merge_requests/7", instances: both)?.instance == main.baseURL)
    }
}
