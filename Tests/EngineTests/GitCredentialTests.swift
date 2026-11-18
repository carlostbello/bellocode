import BelloCore
import ContainerKit
import Foundation
import Testing

@testable import Engine

/// The app-owned HTTPS credential path (docs/features/git-parity.md, "HTTPS credentials").
@Suite("Git credential helper", .timeLimit(.minutes(3)))
struct GitCredentialTests {
    static let token = "glpat-TEST-\(UUID().uuidString.prefix(12))"

    @Test func helperValueQuotesThePath() {
        #expect(GitCredentialHelper.helperValue(path: "/a b/it's/bellocode-exec") == #"!'/a b/it'\''s/bellocode-exec' --git-credential"#)
        let fields = GitCredentialHelper.parse(Data("protocol=https\nhost=h:8443\ncapability[]=authtype\n\nignored=1\n".utf8))
        #expect(fields == ["protocol": "https", "host": "h:8443"])
        #expect(GitCredentialHelper.encode([("a", "1"), ("bad", "x\ny")]) == Data("a=1\n\n".utf8))
    }

    @Test func remoteURLsAndHTTPSEquivalents() throws {
        let instance = try #require(GitLabInstance(baseURL: "https://gitlab.novacoast.com"))
        let scp = try #require(GitRemoteURL("git@gitlab.novacoast.com:group/sub/project.git"))
        #expect(scp.isSSH && scp.host == "gitlab.novacoast.com" && scp.projectPath == "group/sub/project")
        #expect(scp.httpsEquivalent(on: instance) == "https://gitlab.novacoast.com/group/sub/project.git")
        let ssh = try #require(GitRemoteURL("ssh://git@gitlab.novacoast.com:2222/group/project"))
        #expect(ssh.isSSH && ssh.port == 2222 && ssh.httpsEquivalent(on: instance) == "https://gitlab.novacoast.com/group/project.git")
        #expect(GitRemoteURL("git@github.com:a/b.git")?.httpsEquivalent(on: instance) == nil)
        let prefixed = try #require(GitLabInstance(baseURL: "https://code.example.com/gitlab"))
        #expect(GitRemoteURL("git@code.example.com:group/p.git")?.httpsEquivalent(on: prefixed) == "https://code.example.com/gitlab/group/p.git")
        #expect(GitRemoteURL("/local/path") == nil)
    }

    @Test func scopesFollowGitLabDocumentation() {
        #expect(GitTokenScopes.problem(.read, scopes: nil) == nil)
        #expect(GitTokenScopes.problem(.read, scopes: ["api"]) == nil)
        #expect(GitTokenScopes.problem(.write, scopes: ["api"]) == nil)
        #expect(GitTokenScopes.problem(.read, scopes: ["read_repository"]) == nil)
        #expect(GitTokenScopes.problem(.write, scopes: ["read_repository"]) != nil)
        #expect(GitTokenScopes.problem(.read, scopes: ["read_api"]) != nil)
        #expect(GitTokenScopes.problem(.write, scopes: ["write_repository"]) == nil)
    }

    @Test func brokerAnswersOnlyAGrantedDescendantOverHTTPSForAConfiguredHost() throws {
        let vault = InMemorySecretVault()
        try vault.store(account: "https://gitlab.example.com", label: "t", value: SecretValue(Self.token))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([GitLabInstance(baseURL: "https://gitlab.example.com")!])
        let origin = GitCredentialBroker.Origin(host: "gitlab.example.com", port: 443)
        let grant = broker.grant(origins: [origin])
        broker.bind(grant, pid: getpid())
        func ask(_ fields: [String: String], peer: pid_t = getpid()) -> [String: String]? {
            broker.answer(fields.merging(["grant": grant.identifier, "operation": "get"]) { $1 }, peer: peer)
                .map(GitCredentialHelper.parse)
        }
        #expect(ask(["protocol": "https", "host": "gitlab.example.com"])?["password"] == Self.token)
        #expect(ask(["protocol": "http", "host": "gitlab.example.com"]) == nil)
        #expect(ask(["protocol": "https", "host": "gitlab.example.com:8443"]) == nil)
        #expect(ask(["protocol": "https", "host": "evil.example.com"]) == nil)
        // A wrong grant, and a peer that is not the granted process or its descendant.
        #expect(broker.answer(["grant": "00", "operation": "get", "protocol": "https", "host": "gitlab.example.com"], peer: getpid()) == nil)
        let other = Process()
        other.executableURL = URL(filePath: "/bin/cat")
        other.standardInput = Pipe()
        try other.run()
        defer { other.terminate() }
        let foreign = broker.grant(origins: [origin])
        broker.bind(foreign, pid: other.processIdentifier)
        #expect(broker.answer(["grant": foreign.identifier, "operation": "get", "protocol": "https", "host": "gitlab.example.com"], peer: getpid()) == nil)
        #expect(broker.outcomes(foreign) == [.refused("not a process BelloCode launched")])
        // Revoked grants answer nothing.
        broker.revoke(grant)
        #expect(ask(["protocol": "https", "host": "gitlab.example.com"]) == nil)
    }

    // MARK: End to end over HTTPS

    struct Setup {
        let server: HTTPSGitServer
        let repo: TempRepo
        let runner: GitRunner
        let broker: GitCredentialBroker
        let instance: GitLabInstance
        var remote: String { server.url + "/group/project.git" }
        func cleanup() {
            server.stop()
            repo.remove()
        }
    }

    static func setup(storedToken: String = token, helper: Bool = true) async throws -> Setup {
        let server = try HTTPSGitServer(password: token)
        try server.makeRepository("group/project.git")
        let repo = try await TempRepo.make()
        let vault = InMemorySecretVault()
        let instance = try #require(GitLabInstance(baseURL: server.url))
        try vault.store(account: instance.baseURL, label: "t", value: SecretValue(storedToken))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([instance])
        var environment = TempRepo.testRunner.environment
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "http.sslCAInfo"
        environment["GIT_CONFIG_VALUE_0"] = server.caFile
        var runner = GitRunner(environment: environment, writableRoots: [FileManager.default.temporaryDirectory.path])
        if helper, let path = HostGitIsolationTests.helper { runner.credentials = GitCredentials(broker: broker, helperPath: path) }
        let setup = Setup(server: server, repo: repo, runner: runner, broker: broker, instance: instance)
        try await repo.git("remote", "add", "origin", setup.remote)
        return setup
    }

    @Test func pushFetchAndCloneAuthenticateWithTheKeychainToken() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await Self.setup()
        defer { setup.cleanup() }
        let repository = GitRepository(directory: setup.repo.path, runner: setup.runner)
        try await repository.push()
        #expect(setup.server.recorded().contains { $0.authorized && $0.path.hasSuffix("git-receive-pack") })
        _ = try await setup.runner.run(["fetch", "origin"], in: setup.repo.path)
        let clone = setup.repo.base.appending(path: "clone").path
        _ = try await setup.runner.run(["clone", "-q", setup.remote, clone], in: setup.repo.base.path, writableRoots: [setup.repo.base.path])
        #expect(FileManager.default.fileExists(atPath: clone + "/README.md"))
        // The token is in no file of either checkout (config, remote URL, logs written by git) and no grant survives.
        for folder in [setup.repo.path, clone] { #expect(try Self.filesContaining(Self.token, under: folder).isEmpty) }
        #expect(try await setup.repo.git("remote", "get-url", "origin").contains(Self.token) == false)
        #expect(setup.broker.inspect { $0.grants.isEmpty })
    }

    @Test func theTokenIsNeverInArgumentsOrEnvironmentOfTheLaunch() async throws {
        let setup = try await Self.setup()
        defer { setup.cleanup() }
        let credentials = GitCredentialSetup(helperPath: "/x/bellocode-exec", socketPath: "/tmp/s", grant: "g", urls: [setup.remote], remoteNames: ["origin"])
        let launch = try #require(setup.runner.invocation(["push"], in: setup.repo.path, writableRoots: [], trusted: .init(), credentials: credentials))
        #expect(!(launch.arguments.joined() + launch.environment.description).contains(Self.token))
        #expect(launch.environment[GitCredentialHelper.grantVariable] == "g")
        // Local operations never get the helper or the grant.
        let local = try #require(setup.runner.invocation(["status"], in: setup.repo.path, writableRoots: [], trusted: .init(), credentials: credentials))
        #expect(local.environment[GitCredentialHelper.grantVariable] == nil && !local.arguments.joined().contains("CREDENTIAL_HELPER"))
        // opencode's shim path (no credentials) never forwards a grant from its own environment.
        var hostile = setup.runner.environment
        hostile[GitCredentialHelper.grantVariable] = "stolen"
        let shim = try #require(HostGit.invocation(arguments: ["fetch"], directory: setup.repo.path, mode: .network, environment: hostile))
        #expect(shim.environment[GitCredentialHelper.grantVariable] == nil)
    }

    @Test func aRejectedTokenIsReportedAndNothingIsRetriedElsewhere() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await Self.setup(storedToken: "glpat-wrong")
        defer { setup.cleanup() }
        await #expect(throws: GitError.self) { try await GitRepository(directory: setup.repo.path, runner: setup.runner).push() }
        do {
            try await GitRepository(directory: setup.repo.path, runner: setup.runner).push()
        } catch let GitError.authenticationFailed(reason) {
            #expect(reason.contains("rejected"))
        }
        #expect(!setup.server.recorded().contains { $0.authorized })
    }

    @Test func withoutTheHelperNothingAuthenticates() async throws {
        let setup = try await Self.setup(helper: false)
        defer { setup.cleanup() }
        await #expect(throws: GitError.self) { try await GitRepository(directory: setup.repo.path, runner: setup.runner).push() }
        #expect(!setup.server.recorded().contains { $0.hadAuthorization })
    }

    /// A repository (writable from the container) tries every way to get the token: its own helper for the exact
    /// URL (shell builtins only, which the sandbox cannot stop), a proxy, TLS verification off, a host mapping, an
    /// extra header, and an `insteadOf` to another host. The push still reaches the real server with verification
    /// and the token lands in no file.
    @Test func hostileRepositoryConfigurationCannotObtainTheToken() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await Self.setup()
        defer { setup.cleanup() }
        let leak = setup.repo.path + "/.git/leak"
        let config = setup.repo.path + "/.git/config"
        var text = try String(contentsOfFile: config, encoding: .utf8)
        text += """
        [credential "\(setup.remote)"]
        \thelper = "!f() { while read l; do echo \\"$l\\" >> '\(leak)'; done; }; f"
        [credential]
        \thelper = "!f() { while read l; do echo \\"$l\\" >> '\(leak)'; done; }; f"
        [http]
        \tproxy = http://127.0.0.1:9
        \tsslVerify = false
        \tcurloptResolve = 127.0.0.1:\(setup.server.port):127.0.0.2
        \textraHeader = X-Evil: 1
        [http "\(setup.remote)"]
        \tproxy = http://127.0.0.1:9
        [remote "origin"]
        \tproxy = http://127.0.0.1:9

        """
        try text.write(toFile: config, atomically: true, encoding: .utf8)
        try await GitRepository(directory: setup.repo.path, runner: setup.runner).push()
        #expect(setup.server.recorded().contains { $0.authorized })
        let leaked = (try? String(contentsOfFile: leak, encoding: .utf8)) ?? ""
        #expect(!leaked.contains(Self.token))
        #expect(try Self.filesContaining(Self.token, under: setup.repo.base.path).isEmpty)
        // A remote rewritten to another host is refused by the broker (no answer for that host).
        try await setup.repo.git("config", "url.https://localhost:\(setup.server.port)/.insteadOf", setup.server.url + "/")
        try await setup.repo.git("commit", "-q", "--allow-empty", "-m", "second")
        await #expect(throws: GitError.self) { try await GitRepository(directory: setup.repo.path, runner: setup.runner).push() }
    }

    static func filesContaining(_ needle: String, under folder: String) throws -> [String] {
        var found: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: folder)
        while let relative = enumerator?.nextObject() as? String {
            let path = folder + "/" + relative
            if let data = FileManager.default.contents(atPath: path), data.range(of: Data(needle.utf8)) != nil { found.append(relative) }
        }
        return found
    }
}

