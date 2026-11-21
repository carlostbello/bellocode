import Darwin
import Foundation
import Testing
@testable import OpenCodeKit

/// `bellocode-opencode` and the app (docs/reviews/v1.0.0-*.md A03, A13, A24, N06): the connection file holds no
/// secret and is validated strictly, the password comes from the app's socket, the data root has one server at a time,
/// and routing flags cannot slip past the wrapper.
@Suite("CLI handoff", .timeLimit(.minutes(3)))
struct CLIHandoffTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bc-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
    var directories: OpenCodeDirectories { OpenCodeDirectories(dataRoot: root) }
    let opencode = URL(fileURLWithPath: "/Applications/BelloCode.app/Contents/Helpers/opencode")
    let running = OpenCodeCLI.ServerAvailability.running(url: URL(string: "http://127.0.0.1:50123")!, password: "per-launch-secret")

    func plan(_ arguments: [String], _ availability: OpenCodeCLI.ServerAvailability) -> Result<OpenCodeCLI.Invocation, OpenCodeCLI.Refusal> {
        OpenCodeCLI.plan(arguments: arguments, callerEnvironment: ["PATH": "/usr/bin"], directories: directories, opencode: opencode,
                         helpersDirectory: nil, server: { .success(availability) })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    // MARK: Connection file (A03, N06)

    @Test func theConnectionFileHoldsNoPassword() throws {
        defer { cleanUp() }
        try CLIConnectionFile(url: URL(string: "http://127.0.0.1:1")!, pid: getpid(), version: "2.3.2").write(to: directories.connectionFile)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directories.connectionFile)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["url", "pid", "version"])
    }

    @Test func readRefusesLinksLooseFoldersBadPidsAndRemoteURLs() throws {
        defer { cleanUp() }
        let file = directories.connectionFile
        func write(_ json: String) throws {
            try FileManager.default.createDirectory(at: directories.runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(file.path)
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            _ = json.withCString { Darwin.write(fd, $0, strlen($0)) }
            close(fd)
        }
        func refused(_ json: String, _ check: (CLIConnectionFile.ReadError) -> Bool) throws {
            try write(json)
            do {
                _ = try CLIConnectionFile.read(from: file)
                Issue.record("accepted \(json)")
            } catch {
                #expect(check(error), "\(json): \(error)")
            }
        }
        let me = getpid()
        try refused(#"{"url":"http://127.0.0.1:1","pid":0,"version":"x"}"#) { if case .insecure = $0 { true } else { false } }
        try refused(#"{"url":"http://127.0.0.1:1","pid":-1,"version":"x"}"#) { if case .insecure = $0 { true } else { false } }
        try refused(#"{"url":"http://example.com:1","pid":\#(me),"version":"x"}"#) { if case .insecure = $0 { true } else { false } }
        try refused(#"{"url":"https://127.0.0.1:1","pid":\#(me),"version":"x"}"#) { if case .insecure = $0 { true } else { false } }
        try write(#"{"url":"http://127.0.0.1:1","pid":\#(me),"version":"x"}"#)
        #expect(try CLIConnectionFile.read(from: file).pid == me)
        // A folder readable by the group is refused (0o077, not just 0o022).
        chmod(directories.runDirectory.path, 0o750)
        #expect(throws: CLIConnectionFile.ReadError.self) { try CLIConnectionFile.read(from: file) }
        chmod(directories.runDirectory.path, 0o700)
        // A link to a valid file is refused (O_NOFOLLOW).
        let real = directories.runDirectory.appending(path: "real.json")
        try FileManager.default.moveItem(at: file, to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        #expect(throws: CLIConnectionFile.ReadError.insecure("it is a symbolic link")) { try CLIConnectionFile.read(from: file) }
        // A folder that cannot be examined is not "missing".
        unlink(file.path)
        chmod(directories.runDirectory.path, 0o000)
        defer { chmod(directories.runDirectory.path, 0o700) }
        do {
            _ = try CLIConnectionFile.read(from: file)
            Issue.record("read through an unsearchable folder")
        } catch {
            #expect(error != .missing)
        }
    }

    // MARK: Routing (N06)

    @Test func standaloneWithAValueAndVersionNextToASubcommandAreRouted() throws {
        guard case .failure = plan(["auth", "list", "--standalone=true"], running) else { Issue.record("--standalone=true allowed"); return }
        // `-v` beside a subcommand is not a version request: the command still goes to BelloCode's server.
        let run = try plan(["run", "-v", "hello"], running).get()
        #expect(run.arguments.contains("--server") && run.environment["OPENCODE_PASSWORD"] == "per-launch-secret")
        guard case .failure = plan(["run", "-v", "hello"], .offline) else { Issue.record("run without BelloCode allowed"); return }
        #expect(try plan(["-v"], .offline).get().arguments == ["-v"])
        // Refused commands stay refused with help flags.
        guard case .failure = plan(["serve", "--help"], .offline) else { Issue.record("serve --help ran"); return }
    }

    @Test func aBusyDataRootIsRefusedNeverAPrivateServer() throws {
        guard case .failure(let refusal) = plan(["auth", "list"], .busy) else { Issue.record("busy data root used"); return }
        #expect(refusal.message.contains("Try again"))
    }

    /// A24/N06: `BELLOCODE_OPENCODE_BINARY` only in debug builds (this test runs in one; the release branch is the
    /// same function compiled without DEBUG).
    @Test func theBinaryOverrideIsDebugOnly() {
        let helpers = URL(fileURLWithPath: "/Applications/BelloCode.app/Contents/Helpers", isDirectory: true)
        let chosen = OpenCodeCLI.opencodeExecutable(environment: ["BELLOCODE_OPENCODE_BINARY": "/tmp/evil"], helpersDirectory: helpers)
        #if DEBUG
        #expect(chosen.path == "/tmp/evil")
        #else
        #expect(chosen.path == helpers.appending(path: "opencode").path)
        #endif
        #expect(OpenCodeCLI.opencodeExecutable(environment: [:], helpersDirectory: helpers).path == helpers.appending(path: "opencode").path)
    }

    // MARK: Password broker (A03)

    @Test func thePasswordComesFromTheAppsSocketToAllowedPeersOnly() throws {
        defer { cleanUp() }
        let broker = try CLIPasswordBroker(directories: directories, pid: 4242, password: "per-launch-secret", allowedPeers: nil)
        #expect(try CLIPasswordClient.password(directories: directories, pid: 4242) == "per-launch-secret")
        // A socket is not a file: reading it as one yields nothing.
        #expect((try? Data(contentsOf: URL(fileURLWithPath: broker.socketPath))) == nil)
        var info = stat()
        #expect(lstat(broker.socketPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
        // Another server's password is never accepted for this pid.
        #expect(throws: CLIPasswordClient.FetchError.self) { try CLIPasswordClient.password(directories: directories, pid: 1) }
        broker.stop()
        #expect(lstat(broker.socketPath, &info) != 0)

        // Only the bundled helper may ask when one is configured: this test process is not it.
        let strict = try CLIPasswordBroker(directories: directories, pid: 4242, password: "per-launch-secret", allowedPeers: ["/Applications/BelloCode.app/Contents/Helpers/bellocode-opencode"])
        defer { strict.stop() }
        #expect(throws: CLIPasswordClient.FetchError.self) { try CLIPasswordClient.password(directories: directories, pid: 4242) }
    }

    // MARK: One server per data root (A13)

    @Test func twoPrivateServersCannotHoldTheDataRootAtOnce() throws {
        defer { cleanUp() }
        let first = try #require(try OpenCodeDataLock.tryAcquire(directories))
        #expect(try OpenCodeDataLock.tryAcquire(directories) == nil)
        // The second command sees no published server: busy, not offline.
        let (availability, lock) = OpenCodeCLI.discover(directories)
        #expect(lock == nil)
        #expect(try availability.get() == .busy)
        first.release()
        let (again, held) = OpenCodeCLI.discover(directories)
        #expect(try again.get() == .offline)
        #expect(held != nil)
    }

    @Test func theAppWaitsForAPrivateServerAndPublishesWithoutAPassword() async throws {
        defer { cleanUp() }
        let cli = try #require(try OpenCodeDataLock.tryAcquire(directories))
        let launcher = FakeLauncher(pidBase: getpid())
        let configuration = ServerConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"), dataRoot: root, helpersDirectory: URL(fileURLWithPath: "/opt/helpers"),
            startTimeout: .seconds(20), stopGracePeriod: .seconds(3),
            restartBackoff: BackoffPolicy(initial: .milliseconds(200), maximum: .seconds(30), jitter: 0.2), maxConsecutiveFailures: 2,
            healthyAfter: .seconds(30))
        let supervisor = ServerSupervisor(configuration: configuration, launcher: launcher, probe: FakeProbe(launcher: launcher))
        await supervisor.start()
        let waiting = try await within(.seconds(10)) {
            for await state in await supervisor.states() {
                if case .restarting(_, _, let reason) = state { return reason }
            }
            throw CancellationError()
        }
        #expect(waiting.contains("bellocode-opencode"))
        #expect(launcher.processes.isEmpty, "no second server while the CLI holds the data")
        cli.release()
        // Waiting is not a failure: it does not give up after maxConsecutiveFailures.
        let endpoint = try await within(.seconds(10)) { try await supervisor.awaitReady() }
        #expect(try OpenCodeDataLock.tryAcquire(directories) == nil, "the app holds the data while its server runs")
        let file = try CLIConnectionFile.read(from: directories.connectionFile)
        #expect(file.pid == getpid())
        let raw = try String(contentsOf: directories.connectionFile, encoding: .utf8)
        #expect(!raw.contains(endpoint.connection.credentials.password))
        let (availability, _) = OpenCodeCLI.discover(directories)
        #expect(try availability.get() == .running(url: endpoint.baseURL, password: endpoint.connection.credentials.password))
        await supervisor.stop()
        #expect(!FileManager.default.fileExists(atPath: directories.connectionFile.path))
        let after = try OpenCodeDataLock.tryAcquire(directories)
        #expect(after != nil, "released when the server has exited")
    }
}
