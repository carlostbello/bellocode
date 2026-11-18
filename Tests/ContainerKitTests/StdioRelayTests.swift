import Darwin
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// `bellocode-exec --stdio` (local MCP servers in the container): the relay against the fake daemon, the in-container
/// wrapper run by a real `/bin/sh`, and argument parsing.
@Suite("Stdio relay", .timeLimit(.minutes(3)))
struct StdioRelayTests {
    /// A fake daemon whose exec echoes stdin back (stdout), reports how many bytes it received on stderr when stdin
    /// ends, and exits with `exitCode`.
    final class Probe: Sendable {
        let received = Mutex(0)
        let endedByEOF = Mutex(false)
    }

    static func echoServer(exitCode: Int, probe: Probe) throws -> FakeEngineServer {
        try FakeEngineServer { request, stream in
            switch request.path {
            case let path where path.hasSuffix("/exec"):
                try await stream.respond(201, json: #"{"Id":"exec1"}"#)
            case let path where path.hasSuffix("/start"):
                try await stream.write(Data("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n".utf8))
                var total = 0
                while let data = try? await stream.read(), !data.isEmpty {
                    total += data.count
                    try await stream.write(StreamDemuxer.frame(.stdout, data))
                }
                probe.received.withLock { $0 = total }
                probe.endedByEOF.withLock { $0 = true }
                try await stream.write(StreamDemuxer.frame(.stderr, Data("received \(total)\n".utf8)))
            case let path where path.hasSuffix("/json"):
                try await stream.respond(200, json: #"{"ID":"exec1","Running":false,"ExitCode":\#(exitCode),"Pid":9}"#)
            default:
                try await stream.respond(404, json: #"{"message":"?"}"#)
            }
        }
    }

    /// Input fed in the given pieces, then end of input.
    final class Feeder: Sendable {
        let pieces: Mutex<[Data]>
        let reads = Mutex(0)
        init(_ pieces: [Data]) { self.pieces = Mutex(pieces) }
        func next() async throws -> Data {
            reads.withLock { $0 += 1 }
            return pieces.withLock { $0.isEmpty ? Data() : $0.removeFirst() }
        }
    }

    final class Sink: Sendable {
        let stdout = Mutex(Data())
        let stderr = Mutex(Data())
        func write(_ chunk: OutputChunk) {
            if chunk.stream == .stderr { stderr.withLock { $0.append(chunk.bytes) } } else { stdout.withLock { $0.append(chunk.bytes) } }
        }
    }

    static func start(_ server: FakeEngineServer) async throws -> ExecSession {
        try await ExecSession.start(client: server.client, container: "c1", argv: StdioRelay.wrapper(token: "t", ["mcp-server"]),
                                    workingDir: "/w", environment: [:], tty: false)
    }

    @Test func jsonRPCMessagesCrossUnchangedAndEndOfInputEndsTheProgram() async throws {
        let probe = Probe()
        let server = try Self.echoServer(exitCode: 0, probe: probe)
        defer { server.stop() }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n",
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"héllo\u0000\r\n"}}}"# + "\n",
        ]
        let feeder = Feeder(messages.map { Data($0.utf8) })
        let sink = Sink()
        let code = try await StdioRelay.run(session: try await Self.start(server), readInput: feeder.next, writeOutput: sink.write)
        #expect(code == 0)
        #expect(sink.stdout.withLock { $0 } == Data(messages.joined().utf8), "bytes pass unchanged: no TTY translation, no buffering loss")
        #expect(probe.endedByEOF.withLock { $0 }, "end of the host's input reaches the program as end of input")
        #expect(String(decoding: sink.stderr.withLock { $0 }, as: UTF8.self) == "received \(messages.joined().utf8.count)\n",
                "stderr stays separate from the protocol stream")
    }

    @Test func partialWritesAreForwardedPieceByPiece() async throws {
        let probe = Probe()
        let server = try Self.echoServer(exitCode: 0, probe: probe)
        defer { server.stop() }
        // One message split at every byte boundary (as a pipe may deliver it).
        let message = Data(#"{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"ok"}]}}"#.utf8) + Data([10])
        let feeder = Feeder(message.map { Data([$0]) })
        let sink = Sink()
        _ = try await StdioRelay.run(session: try await Self.start(server), readInput: feeder.next, writeOutput: sink.write)
        #expect(sink.stdout.withLock { $0 } == message)
        #expect(probe.received.withLock { $0 } == message.count)
    }

    @Test func largeMessagesAreRelayedInBoundedChunksAndExitCodePropagates() async throws {
        let probe = Probe()
        let server = try Self.echoServer(exitCode: 42, probe: probe)
        defer { server.stop() }
        // 4 MiB in one JSON-RPC message, read in chunks of at most `chunkSize` (the relay never holds more than one).
        var payload = Data(#"{"jsonrpc":"2.0","id":3,"result":""#.utf8)
        payload.append(Data(repeating: UInt8(ascii: "x"), count: 4 << 20))
        payload.append(Data(#""}"#.utf8) + Data([10]))
        let chunks = stride(from: 0, to: payload.count, by: StdioRelay.chunkSize).map { payload[$0..<min($0 + StdioRelay.chunkSize, payload.count)] }
        let feeder = Feeder(chunks.map { Data($0) })
        let sink = Sink()
        let code = try await StdioRelay.run(session: try await Self.start(server), readInput: feeder.next, writeOutput: sink.write)
        #expect(code == 42, "the program's exit code becomes the helper's")
        #expect(sink.stdout.withLock { $0 } == payload)
        #expect(chunks.allSatisfy { $0.count <= StdioRelay.chunkSize })
    }

    @Test func theExecIsCreatedWithoutTTYWithStdinAndTheRelayMarker() async throws {
        let probe = Probe()
        let server = try Self.echoServer(exitCode: 0, probe: probe)
        defer { server.stop() }
        _ = try await StdioRelay.run(session: try await Self.start(server), readInput: Feeder([]).next, writeOutput: { _ in })
        let create = try #require(server.requests.withLock { $0.first { $0.path.hasSuffix("/exec") } })
        let body = try #require(try JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        #expect(body["Tty"] as? Bool == false)
        #expect(body["AttachStdin"] as? Bool == true)
        let cmd = try #require(body["Cmd"] as? [String])
        #expect(cmd.count == 5 && cmd[3] == StdioRelay.processName && cmd[4] == "mcp-server")
        let inspect = try JSONDecoder().decode(
            ExecInspect.self, from: Data(#"{"ID":"e","Running":true,"ProcessConfig":{"entrypoint":"/bin/sh","arguments":["-c","x","bellocode-stdio","node"]}}"#.utf8))
        #expect(inspect.isRelayedProgram, "a relayed program does not count as a running command for idle stop")
    }

    // MARK: The in-container wrapper, run by the Mac's /bin/sh (POSIX, like the container's)

    /// Runs the wrapper with `program` and returns (exit status, stdout). `input` is written and stdin closed; with
    /// `signal`, the recorded process group gets it once the program is running.
    static func runWrapper(_ program: [String], input: Data, signal: Int32? = nil) throws -> (Int32, String) {
        let token = "test-\(UUID().uuidString.prefix(8))"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        let argv = StdioRelay.wrapper(token: token, program)
        process.arguments = Array(argv.dropFirst())
        let stdin = Pipe(), stdout = Pipe()
        // The program may exit before reading its input: the write then fails with EPIPE instead of raising SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? FileManager.default.removeItem(atPath: "/tmp/.bellocode/\(token).pid") }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        if let signal {
            // Wait until the program runs (it echoes the input), then signal the wrapper as the host's kill does.
            let first = stdout.fileHandleForReading.availableData
            kill(process.processIdentifier, signal)
            process.waitUntilExit()
            try? stdin.fileHandleForWriting.close()
            return (process.terminationStatus, String(decoding: first, as: UTF8.self))
        }
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test func wrapperGivesTheProgramItsStdinAndExitStatus() throws {
        let (status, output) = try Self.runWrapper(["/bin/sh", "-c", "cat; exit 3"], input: Data("line one\nline two\n".utf8))
        #expect(output == "line one\nline two\n", "the background program reads the exec's stdin, not /dev/null")
        #expect(status == 3)
    }

    @Test func wrapperPassesTerminationToTheProgram() throws {
        // The program would run for a minute; TERM to the wrapper ends it (and the wrapper reports 128+15).
        let (status, first) = try Self.runWrapper(["/bin/sh", "-c", "head -c 3; exec sleep 60"], input: Data("abc".utf8), signal: SIGTERM)
        #expect(first == "abc")
        #expect(status == 143 || status == 15, "terminated, not left running (status \(status))")
    }

    @Test func wrapperRecordsItsProcessGroupForTheHostsKill() throws {
        let (status, output) = try Self.runWrapper(["/bin/sh", "-c", "ls /tmp/.bellocode/ | grep -c pid"], input: Data())
        #expect(status == 0 && (Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) >= 1)
    }

    // MARK: Arguments

    @Test func argumentsSelectTheMode() throws {
        #expect(try HelperInvocation.parse(["-c", "ls"]) == .command("ls"))
        #expect(try HelperInvocation.parse(["-l", "+o", "nomatch", "-c", "ls"]) == .command("ls"))
        #expect(try HelperInvocation.parse([]) == .command(nil))
        #expect(try HelperInvocation.parse(["--version"]) == .version)
        #expect(try HelperInvocation.parse(["--stdio", "--project", "/p", "--", "node", "mcp.js"]) == .stdio(project: "/p", argv: ["node", "mcp.js"]))
        #expect(try HelperInvocation.parse(["--stdio", "--", "x"]) == .stdio(project: nil, argv: ["x"]))
        #expect(try HelperInvocation.parse(["--stdio", "--refuse", "tools"]) == .refuse(name: "tools"))
        #expect(try HelperInvocation.parse(["--service", "db", "--project", "/p"]) == .service(project: "/p", name: "db"))
        #expect(throws: HelperInvocation.ParseError.self) { try HelperInvocation.parse(["--stdio", "--project", "/p"]) }
        #expect(throws: HelperInvocation.ParseError.self) { try HelperInvocation.parse(["--stdio", "--unknown", "--", "x"]) }
        #expect(throws: HelperInvocation.ParseError.self) { try HelperInvocation.parse(["-c"]) }
        #expect(HelperInvocation.refusalMessage(server: "tools").contains("Project Settings ▸ Environment ▸ MCP servers"))
    }
}
