// bellocode-opencode: the opencode command-line interface on BelloCode's isolated opencode data
// (docs/features/opencode-config.md, "Command-line tool"). Bundled in Contents/Helpers next to the pinned opencode;
// "Install Command Line Tool…" links it into ~/.local/bin. All decisions are in `OpenCodeCLI.plan` (OpenCodeKit).

import Darwin
import Foundation
import OpenCodeKit

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("bellocode-opencode: \(message)\n".utf8))
    exit(code)
}

/// This executable's real location (an installed symlink resolved), so the bundled opencode beside it is found.
func executableDirectory() -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else {
        fail("cannot locate this executable")
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved)).deletingLastPathComponent()
}

let environment = ProcessInfo.processInfo.environment
let helpers = executableDirectory()
let opencode = environment["BELLOCODE_OPENCODE_BINARY"].map { URL(fileURLWithPath: $0) } ?? helpers.appending(path: "opencode")
guard FileManager.default.isExecutableFile(atPath: opencode.path) else {
    fail("no bundled opencode at \(opencode.path); reinstall the command-line tool from BelloCode (Settings ▸ opencode)")
}
let directories = OpenCodeDirectories(dataRoot: OpenCodeCLI.defaultDataRoot(environment: environment))

var connection: CLIConnectionFile?
do {
    connection = try CLIConnectionFile.read(from: directories.connectionFile)
} catch .missing, .stale {
    connection = nil
} catch {
    fail(error.description)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch OpenCodeCLI.plan(
    arguments: arguments, callerEnvironment: environment, directories: directories, opencode: opencode,
    helpersDirectory: helpers, connection: connection)
{
case .failure(let refusal):
    fail(refusal.message)
case .success(let invocation):
    if let notice = invocation.notice { FileHandle.standardError.write(Data("bellocode-opencode: \(notice)\n".utf8)) }
    for directory in [directories.home, directories.config, directories.data, directories.state, directories.cache] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let argv = [invocation.executable.path] + invocation.arguments
    let envp = invocation.environment.map { "\($0.key)=\($0.value)" }
    var cArgs = argv.map { strdup($0) } + [nil]
    var cEnv = envp.map { strdup($0) } + [nil]
    execve(invocation.executable.path, &cArgs, &cEnv)
    fail("could not run \(invocation.executable.path): \(String(cString: strerror(errno)))", code: 126)
}
