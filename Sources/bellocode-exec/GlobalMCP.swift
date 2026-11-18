// `bellocode-exec --stdio --mcp ID [--project DIR]`: a global image-based MCP server (Settings ▸ MCP Servers). The
// image runs in its own container through the Engine API, like `docker run -i --rm IMAGE ARGS`, with no project
// folder mounted; stdin and stdout are relayed unchanged; stderr goes to opencode and to a bounded log file. Never
// pulls and never falls back to the Mac.

import ContainerKit
import Darwin
import Dispatch
import Foundation

@MainActor
func runGlobalMCP(id: String, project: String?, config: ExecHelperConfig, environment: [String: String], hostDirectory: String) async -> Never {
    func fail(_ code: Int32, _ message: String) -> Never {
        FileHandle.standardError.write(Data("BelloCode: \(message) The MCP server was not started.\n".utf8))
        exit(code)
    }
    guard let spec = config.mcpServers?.first(where: { $0.id == id }) else {
        fail(126, "no MCP server with id \(id) is configured in Settings ▸ MCP Servers (it may have been removed or turned off).")
    }
    if let blocked = spec.blocked { fail(125, "“\(spec.name)”: \(blocked)") }
    // Secret values arrive in this process's environment from opencode's registration (Keychain in the app); only the
    // names the server declares are passed on, never the rest of opencode's environment.
    var secrets: [String: String] = [:]
    for name in spec.secretNames { if let value = environment[name] { secrets[name] = value } }
    let scope = spec.shared ? nil : WorkspaceSpec.projectKey(for: project ?? hostDirectory)
    let token = String(UUID().uuidString.prefix(12).lowercased())
    let client = EngineClient(socketPath: config.socket)
    let log = config.mcpLogDirectory.map { BoundedLogFile(url: URL(filePath: $0).appending(path: "\(id).log")) }

    let session: any StdioSession
    do {
        session = try await ImageMCPRunner(client: client).start(spec, scope: scope, secrets: secrets, token: token)
    } catch let error as SocketError where error.isConnectionRefusedOrMissing {
        fail(125, RuntimeState.notRunning(socketPath: config.socket).userMessage)
    } catch let error as ImageMCPError {
        log?.append(Data("[bellocode] could not start: \(error.description)\n".utf8))
        fail(125, "“\(spec.name)”: \(error.description)")
    } catch {
        fail(125, "“\(spec.name)” could not start (\(ContainerError.from(error).description)).")
    }

    @Sendable func stopInContainer() async {
        if let attached = session as? AttachSession {
            await attached.terminate()
        } else {
            _ = try? await ExecSession.run(client: client, container: spec.containerName(scope: nil),
                                           argv: ExecWrapper.killSession(token: token, signal: "TERM"), wrap: false, timeout: .seconds(5))
        }
    }

    // opencode disconnecting (server removed, restarted, location disposed) sends TERM: end the input, stop the program
    // in its container (TERM, KILL after a few seconds), remove a per-connection container, then leave.
    let queue = DispatchQueue.main
    var sources: [any DispatchSourceSignal] = []
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            session.closeStdin()
            Task {
                await stopInContainer()
                exit(128 + sig)
            }
            // Wall deadline: an uptime-clock timer may not fire while the process is idle (macOS 27).
            queue.asyncAfter(wallDeadline: .now() + 8) { exit(128 + sig) }
        }
        source.resume()
        sources.append(source)
    }
    _ = sources

    let input = FileStream(fd: STDIN_FILENO, owned: false, isSocket: false)
    let stdoutStream = FileStream(fd: STDOUT_FILENO, owned: false, isSocket: false)
    let stderrStream = FileStream(fd: STDERR_FILENO, owned: false, isSocket: false)
    let code: Int
    do {
        code = try await StdioRelay.run(
            session: session, readInput: { try await input.read(maxLength: StdioRelay.chunkSize) },
            writeOutput: { chunk in
                switch chunk.stream {
                case .stderr, .system:
                    log?.append(chunk.bytes)
                    try stderrStream.writeAllBlocking(chunk.bytes)
                default:
                    try stdoutStream.writeAllBlocking(chunk.bytes)
                }
            })
    } catch {
        await stopInContainer()
        FileHandle.standardError.write(Data("BelloCode: the MCP server's stream ended unexpectedly; its container was stopped.\n".utf8))
        exit(125)
    }
    if code != 0 { log?.append(Data("[bellocode] exited with status \(code)\n".utf8)) }
    exit(Int32(truncatingIfNeeded: code < 0 ? 125 : code))
}
