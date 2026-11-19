import Foundation
import Testing

@testable import ContainerKit

/// R14: the Dockerfile is found in plain and gzip build contexts (Compose's classic builder and `docker build
/// --compress` send gzip), at any chunking; other compressions and corrupt gzip are refused.
@Suite("Build context scanner", .timeLimit(.minutes(3)))
struct BuildContextScannerTests {
    static let dockerfile = "FROM registry.acme.internal/base:1\nRUN true\n"

    /// A context whose Dockerfile comes after a larger file, so the scan crosses many DEFLATE outputs.
    static func tar() -> Data {
        var archive = TarArchive()
        archive.add("app/main.js", String(repeating: "console.log('bellocode')\n", count: 20_000))
        archive.add("Dockerfile", dockerfile)
        return archive.data()
    }

    /// Real gzip from /usr/bin/gzip, of a named file (so the header carries FNAME).
    static func gzip(_ data: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bc-gz-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "context.tar")
        try data.write(to: file)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-k", "-N", file.path]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return try Data(contentsOf: directory.appending(path: "context.tar.gz"))
    }

    static func scan(_ body: Data, chunk: Int, dockerfile: String? = nil) -> BuildContextScanner.Outcome {
        var scanner = BuildContextScanner(dockerfile: dockerfile)
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = min(offset + chunk, body.endIndex)
            if let outcome = scanner.feed(body.subdata(in: offset..<end)) { return outcome }
            offset = end
        }
        return scanner.finish()
    }

    @Test(arguments: [1, 7, 513, 1 << 30])
    func gzipAndPlainContextsYieldTheDockerfile(chunk: Int) throws {
        let tar = Self.tar()
        let compressed = try Self.gzip(tar)
        #expect(compressed.prefix(2) == Data([0x1f, 0x8b]) && compressed[compressed.startIndex + 3] & 0x08 != 0, "gzip with FNAME")
        #expect(Self.scan(tar, chunk: chunk) == .found(Data(Self.dockerfile.utf8)))
        #expect(Self.scan(compressed, chunk: chunk) == .found(Data(Self.dockerfile.utf8)))
        #expect(Self.scan(compressed, chunk: chunk, dockerfile: "ci/Dockerfile") == .missing)
    }

    @Test func headerFieldsAreSkippedWhereverTheyAreSplit() throws {
        // FEXTRA (4 bytes), FNAME, FCOMMENT and FHCRC before the DEFLATE body of the real stream.
        let real = try Self.gzip(Self.tar())
        let bodyStart = try #require(try GzipInflater.headerLength(real))
        var header: [UInt8] = [0x1f, 0x8b, 8, 0x04 | 0x08 | 0x10 | 0x02, 0, 0, 0, 0, 0, 3]
        header += [4, 0, 1, 2, 3, 4] + Array("ctx.tar".utf8) + [0] + Array("a comment".utf8) + [0] + [0xAB, 0xCD]
        let crafted = Data(header) + real.subdata(in: real.startIndex + bodyStart..<real.endIndex)
        #expect(try GzipInflater.headerLength(crafted) == header.count)
        for chunk in [1, 3, 11] {
            #expect(Self.scan(crafted, chunk: chunk) == .found(Data(Self.dockerfile.utf8)), "chunk \(chunk)")
        }
    }

    @Test func otherCompressionsAndCorruptGzipAreRefused() {
        let bzip2 = Data([0x42, 0x5a, 0x68, 0x39, 0x31, 0x41] + [UInt8](repeating: 0, count: 600))
        guard case .refused(let reason)? = Optional(Self.scan(bzip2, chunk: 2)) else { Issue.record("bzip2 not refused"); return }
        #expect(reason.contains("compressed"))
        let corrupt = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3] + [UInt8](repeating: 0xFF, count: 600))
        guard case .refused(let why) = Self.scan(corrupt, chunk: 64) else { Issue.record("corrupt gzip not refused"); return }
        #expect(why.contains("not valid gzip"))
        #expect(Self.scan(Data([0x1f, 0x8b, 9, 0, 0, 0, 0, 0, 0, 3, 0, 0]), chunk: 64) != .found(Data()), "only DEFLATE")
    }

    @Test func aShortBodyIsTreatedAsTar() {
        #expect(Self.scan(Data([0x1f]), chunk: 1) == .missing, "fewer than six bytes: no Dockerfile")
    }
}
