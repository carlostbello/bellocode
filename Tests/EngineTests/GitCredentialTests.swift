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
        let instance = GitLabInstance(baseURL: "https://gitlab.example.com")!
        broker.setInstances([instance])
        let grant = broker.grant(instances: [instance])
        broker.bind(grant, pid: getpid())
        func ask(_ fields: [String: String], peer: pid_t = getpid()) -> [String: String]? {
            broker.answer(fields.merging(["grant": grant.identifier, "operation": "get"]) { $1 }, peer: peer)
                .map(GitCredentialHelper.parse)
        }
        let path = "group/project.git"
        #expect(ask(["protocol": "https", "host": "gitlab.example.com", "path": path])?["password"] == Self.token)
        #expect(ask(["protocol": "http", "host": "gitlab.example.com", "path": path]) == nil)
        #expect(ask(["protocol": "https", "host": "gitlab.example.com:8443", "path": path]) == nil)
        #expect(ask(["protocol": "https", "host": "evil.example.com", "path": path]) == nil)
        #expect(ask(["protocol": "https", "host": "gitlab.example.com"]) == nil, "git always sends the path (useHttpPath); none: no answer")
        // A wrong grant, and a peer that is not the granted process or its descendant.
        #expect(broker.answer(["grant": "00", "operation": "get", "protocol": "https", "host": "gitlab.example.com", "path": path], peer: getpid()) == nil)
        let other = Process()
        other.executableURL = URL(filePath: "/bin/cat")
        other.standardInput = Pipe()
        try other.run()
        defer { other.terminate() }
        let foreign = broker.grant(instances: [instance])
        broker.bind(foreign, pid: other.processIdentifier)
        #expect(broker.answer(["grant": foreign.identifier, "operation": "get", "protocol": "https", "host": "gitlab.example.com", "path": path],
                              peer: getpid()) == nil)
        #expect(broker.outcomes(foreign) == [.refused("not a process BelloCode launched")])
        // Revoked grants answer nothing.
        broker.revoke(grant)
        #expect(ask(["protocol": "https", "host": "gitlab.example.com", "path": path]) == nil)
    }

    /// R10: two GitLab installations behind different path prefixes of one HTTPS host (a reverse proxy) each get only
    /// their own token, whatever order they are configured in; a grant for one never answers for the other.
    @Test func installationsSharingAHostNeverReceiveEachOthersToken() throws {
        let vault = InMemorySecretVault()
        let a = GitLabInstance(baseURL: "https://code.example.com/team-a")!
        let b = GitLabInstance(baseURL: "https://code.example.com/team-b")!
        let root = GitLabInstance(baseURL: "https://code.example.com")!
        try vault.store(account: a.baseURL, label: "a", value: SecretValue("glpat-team-a"))
        try vault.store(account: b.baseURL, label: "b", value: SecretValue("glpat-team-b"))
        try vault.store(account: root.baseURL, label: "r", value: SecretValue("glpat-root"))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([root, a, b])
        let both = broker.grant(instances: [a, b, root])
        broker.bind(both, pid: getpid())
        func ask(_ grant: GitCredentialBroker.Grant, _ path: String) -> String? {
            broker.answer(["grant": grant.identifier, "operation": "get", "protocol": "https", "host": "code.example.com", "path": path], peer: getpid())
                .map(GitCredentialHelper.parse)?["password"]
        }
        #expect(ask(both, "team-a/group/project.git") == "glpat-team-a")
        #expect(ask(both, "team-b/group/project.git") == "glpat-team-b")
        #expect(ask(both, "other/project.git") == "glpat-root")
        // A grant made for team-a's remote never answers a request for team-b's (or the root installation's) path.
        let onlyA = broker.grant(instances: [a])
        broker.bind(onlyA, pid: getpid())
        #expect(ask(onlyA, "team-a/group/project.git") == "glpat-team-a")
        #expect(ask(onlyA, "team-b/group/project.git") == nil)
        #expect(ask(onlyA, "other/project.git") == nil)
        #expect(broker.outcomes(onlyA).contains(.refused("the repository is not on a GitLab instance this git was allowed to use")))
        // The same installation configured twice is ambiguous: no answer.
        broker.setInstances([a, GitLabInstance(baseURL: "https://code.example.com/team-a/")!])
        #expect(ask(both, "team-a/group/project.git") == nil)
        // git is told to send the path.
        let setup = GitCredentialSetup(helperPath: "/x", socketPath: "/s", grant: "g", urls: ["https://code.example.com/team-a/p.git"], remoteNames: [])
        #expect(setup.overrides.contains { $0 == ("credential.https://code.example.com/team-a/p.git.useHttpPath", "true") })
    }

    /// N10: a path a proxy in front of two installations could resolve differently (dot segments, empty segments,
    /// encoded separators) gets no token, from git's credential request or from a remote URL.
    @Test func pathTraversalAcrossInstallationsGetsNoToken() throws {
        let vault = InMemorySecretVault()
        let a = GitLabInstance(baseURL: "https://code.example.com/team-a")!
        let b = GitLabInstance(baseURL: "https://code.example.com/team-b")!
        try vault.store(account: a.baseURL, label: "a", value: SecretValue("glpat-team-a"))
        try vault.store(account: b.baseURL, label: "b", value: SecretValue("glpat-team-b"))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([a, b])
        let grant = broker.grant(instances: [a])
        broker.bind(grant, pid: getpid())
        func ask(_ path: String) -> String? {
            broker.answer(["grant": grant.identifier, "operation": "get", "protocol": "https", "host": "code.example.com", "path": path], peer: getpid())
                .map(GitCredentialHelper.parse)?["password"]
        }
        #expect(ask("team-a/group/project.git") == "glpat-team-a")
        for hostile in ["team-a/../team-b/repo.git", "team-a/./../team-b/repo.git", "team-a//../team-b/repo.git", "team-a/%2e%2e/team-b/repo.git",
                        "team-a/%2E%2E%2Fteam-b/repo.git", "team-a%2f..%2fteam-b/repo.git", "team-a/..\\team-b/repo.git", "team-a/x/../../team-b/r.git",
                        "team-a/group/./project.git", "team-a//group/project.git"] {
            #expect(ask(hostile) == nil, "\(hostile)")
        }
        for url in ["https://code.example.com/team-a/../team-b/repo.git", "https://code.example.com/team-a/%2e%2e/team-b/repo.git",
                    "https://code.example.com/team-a/%2E%2e%2fteam-b/repo.git", "https://code.example.com/team-a//repo.git"] {
            #expect(broker.instance(forURL: url) == nil, "\(url)")
        }
        #expect(broker.instance(forURL: "https://code.example.com/team-a/group/project.git") == a)
        #expect(GitRemoteURL.isCanonical(path: "group/sub/project.git") && GitRemoteURL.isCanonical(path: "group/project/"))
    }

    /// R10 end to end: the remote is on the more specific installation; the one configured first on the same host has
    /// a different (wrong) token. Push authenticates only when git sends the path and the broker resolves it.
    @Test func gitSendsTheRepositoryPathAndTheMostSpecificInstallationAnswers() async throws {
        _ = try #require(HostGitIsolationTests.helper, "bellocode-exec is not built")
        let setup = try await Self.setup(storedToken: "glpat-wrong-installation")
        defer { setup.cleanup() }
        let specific = try #require(GitLabInstance(baseURL: setup.server.url + "/group"))
        let vault = InMemorySecretVault()
        try vault.store(account: setup.instance.baseURL, label: "root", value: SecretValue("glpat-wrong-installation"))
        try vault.store(account: specific.baseURL, label: "group", value: SecretValue(Self.token))
        let broker = try GitCredentialBroker(tokens: vault)
        broker.setInstances([setup.instance, specific])
        var runner = setup.runner
        runner.credentials = GitCredentials(broker: broker, helperPath: try #require(HostGitIsolationTests.helper))
        try await GitRepository(directory: setup.repo.path, runner: runner).push()
        #expect(setup.server.recorded().contains { $0.authorized && $0.path.hasSuffix("git-receive-pack") })
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

