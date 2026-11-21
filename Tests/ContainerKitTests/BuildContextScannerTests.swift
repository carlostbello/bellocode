import Foundation
import Testing
import zlib

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
        header += [4, 0, 1, 2, 3, 4] + Array("ctx.tar".utf8) + [0] + Array("a comment".utf8) + [0]
        // FHCRC: the low 16 bits of the header's CRC-32 (zlib and Go's reader both check it).
        let crc = header.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
        header += [UInt8(crc & 0xff), UInt8((crc >> 8) & 0xff)]
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
        // Fewer than six bytes: read as tar, which ends inside its first header (Go's reader fails it too).
        guard case .refused = Self.scan(Data([0x1f]), chunk: 1) else { Issue.record("a truncated body was not refused"); return }
        #expect(Self.scan(Data(), chunk: 1) == .missing)
    }
}

/// A08, N04, A22: the Dockerfile judged is the one Docker builds. Raw headers make archives the Docker CLI never
/// writes; each must be refused (or parsed exactly as Go's reader parses it), at every chunking, plain and gzip.
@Suite("Build context scanner: hostile archives", .timeLimit(.minutes(3)))
struct BuildContextScannerHostileTests {
    static let allowed = "FROM registry.acme.internal/base:1\n"
    static let evil = "FROM evil.example.com/exfil:latest\n"

    /// One raw tar header (ustar unless `gnu`), checksum computed unless given.
    static func header(_ name: String, type: Character = "0", size: Int = 0, sizeField: String? = nil, link: String = "",
                       prefix: String = "", gnu: Bool = false, checksum: Int? = nil) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, _ offset: Int, _ length: Int) {
            let bytes = Array(text.utf8.prefix(length))
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        put(name, 0, 100)
        put("0000644", 100, 7)
        put("0000000", 108, 7)
        put("0000000", 116, 7)
        put(sizeField ?? String(format: "%011o", size), 124, 12)
        put("00000000000", 136, 11)
        header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
        header[156] = UInt8(ascii: type.unicodeScalars.first!)
        put(link, 157, 100)
        if gnu { put("ustar  ", 257, 8) } else { put("ustar", 257, 6); put("00", 263, 2) }
        put(prefix, 345, 155)
        let sum = checksum ?? header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), 148, 6)
        header[154] = 0
        header[155] = 0x20
        return header
    }

    static func file(_ name: String, _ text: String, type: Character = "0") -> [UInt8] {
        let data = Array(text.utf8)
        return header(name, type: type, size: data.count) + data + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }

    static func pax(_ records: [(String, String)], type: Character = "x") -> [UInt8] {
        var body: [UInt8] = []
        for (key, value) in records {
            let tail = " \(key)=\(value)\n"
            var length = tail.utf8.count + 1
            while String(length).count + tail.utf8.count != length { length += 1 }
            body += Array("\(length)\(tail)".utf8)
        }
        return header("PaxHeader", type: type, size: body.count) + body + [UInt8](repeating: 0, count: (512 - body.count % 512) % 512)
    }

    static let end = [UInt8](repeating: 0, count: 1024)

    static func gzip(_ data: Data) throws -> Data { try BuildContextScannerTests.gzip(data) }

    /// Plain and gzip, at several chunkings: every outcome must agree.
    static func outcomes(_ bytes: [UInt8], dockerfile: String? = nil) throws -> [BuildContextScanner.Outcome] {
        let plain = Data(bytes)
        var results: [BuildContextScanner.Outcome] = []
        for body in [plain, try gzip(plain)] {
            for chunk in [1, 511, 4096, 1 << 30] { results.append(BuildContextScannerTests.scan(body, chunk: chunk, dockerfile: dockerfile)) }
        }
        return results
    }

    static func expectRefused(_ bytes: [UInt8], dockerfile: String? = nil, containing text: String,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        for outcome in try outcomes(bytes, dockerfile: dockerfile) {
            guard case .refused(let reason) = outcome else {
                Issue.record("not refused: \(outcome)", sourceLocation: sourceLocation)
                return
            }
            #expect(reason.contains(text), "\(reason)", sourceLocation: sourceLocation)
        }
    }

    @Test func aSecondDockerfileLateInTheArchiveIsRefused() throws {
        let padding = Self.file("app/big.js", String(repeating: "x", count: 300_000))
        try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + padding + Self.file("Dockerfile", Self.evil) + Self.end,
                               containing: "more than one entry")
        // The same path spelled differently.
        for alias in ["./Dockerfile", "a/../Dockerfile", "/Dockerfile", "x//../Dockerfile", ".//Dockerfile"] {
            try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + Self.file(alias, Self.evil) + Self.end, containing: "more than one entry")
        }
        try Self.expectRefused(Self.file("ci/Dockerfile", Self.allowed) + Self.file("ci/./x/../Dockerfile", Self.evil) + Self.end,
                               dockerfile: "./ci//Dockerfile", containing: "more than one entry")
    }

    @Test func aSecondDockerfileInAConcatenatedGzipMemberIsRefused() throws {
        let first = try Self.gzip(Data(Self.file("Dockerfile", Self.allowed)))
        let second = try Self.gzip(Data(Self.file("Dockerfile", Self.evil) + Self.end))
        for chunk in [1, 7, 512, 1 << 30] {
            guard case .refused(let reason) = BuildContextScannerTests.scan(first + second, chunk: chunk) else {
                Issue.record("a Dockerfile in a second gzip member was not seen (chunk \(chunk))")
                continue
            }
            #expect(reason.contains("more than one entry"))
        }
        // Members are decoded one after another: a context split across members is read whole.
        let split = try Self.gzip(Data(Self.file("app.js", "x"))) + Self.gzip(Data(Self.file("Dockerfile", Self.allowed) + Self.end))
        for chunk in [1, 9, 1 << 30] { #expect(BuildContextScannerTests.scan(split, chunk: chunk) == .found(Data(Self.allowed.utf8))) }
        // Anything after a member that is not another member fails, as it does in Go's reader.
        let whole = try Self.gzip(Data(Self.file("Dockerfile", Self.allowed) + Self.end))
        for tail in [Data("junk".utf8), Data([0x1f, 0x8b, 9, 0])] {
            guard case .refused = BuildContextScannerTests.scan(whole + tail, chunk: 5) else { Issue.record("trailing bytes accepted"); continue }
        }
        // A member cut short.
        guard case .refused(let reason) = BuildContextScannerTests.scan(whole.prefix(whole.count - 3), chunk: 64) else {
            Issue.record("a truncated member was accepted")
            return
        }
        #expect(reason.contains("gzip") || reason.contains("middle"))
    }

    @Test func linksAtOrAboveTheDockerfileOrUnderALinkAreRefused() throws {
        // The Dockerfile itself as a symlink or hard link.
        try Self.expectRefused(Self.header("Dockerfile", type: "2", link: "evil/Dockerfile") + Self.file("evil/Dockerfile", Self.evil) + Self.end,
                               containing: "passes through a link")
        try Self.expectRefused(Self.file("other", Self.evil) + Self.header("Dockerfile", type: "1", link: "other") + Self.end,
                               containing: "passes through a link")
        // A folder above the Dockerfile as a link, before or after it.
        try Self.expectRefused(Self.file("ci/Dockerfile", Self.allowed) + Self.header("ci", type: "2", link: "evil") + Self.end,
                               dockerfile: "ci/Dockerfile", containing: "passes through a link")
        // An entry written through a link: `d -> .`, then `d/Dockerfile`.
        try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + Self.header("d", type: "2", link: ".") + Self.file("d/Dockerfile", Self.evil)
                               + Self.end, containing: "inside a link")
        // A link elsewhere is fine.
        let fine = Self.header("node_modules/.bin/tool", type: "2", link: "../tool/cli.js") + Self.file("Dockerfile", Self.allowed) + Self.end
        for outcome in try Self.outcomes(fine) { #expect(outcome == .found(Data(Self.allowed.utf8))) }
    }

    @Test func otherEntryTypesAtTheDockerfileAndEscapingNamesAreRefused() throws {
        try Self.expectRefused(Self.header("Dockerfile", type: "5") + Self.end, containing: "not a regular file")
        try Self.expectRefused(Self.header("Dockerfile/", type: "\0") + Self.end, containing: "not a regular file")
        try Self.expectRefused(Self.header("Dockerfile", type: "6") + Self.end, containing: "not a regular file")
        try Self.expectRefused(Self.file("../Dockerfile", Self.evil) + Self.end, containing: "leaves the context")
        try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + Self.end, dockerfile: "../Dockerfile", containing: "leaves the build context")
        try Self.expectRefused(Self.header("sparse", type: "S", size: 10) + Self.end, containing: "sparse")
        try Self.expectRefused(Self.pax([("GNU.sparse.major", "1")]) + Self.file("Dockerfile", Self.allowed) + Self.end, containing: "sparse")
    }

    @Test func paxAndGNUNamesAndSizesFollowGosRules() throws {
        // PAX `size` replaces the header's: the bytes after the entry are read where Go reads them.
        let hidden = Array(Self.allowed.utf8)
        let lie = Self.pax([("size", "0")]) + Self.header("innocent", size: 512) + Self.file("Dockerfile", Self.evil) + Self.end
        let found = try Self.outcomes(lie)
        for outcome in found { #expect(outcome == .found(Data(Self.evil.utf8)), "PAX size followed") }
        _ = hidden
        // A PAX path renames the entry; a GNU long name wins over it.
        for outcome in try Self.outcomes(Self.pax([("path", "Dockerfile")]) + Self.file("x", Self.evil) + Self.end) {
            #expect(outcome == .found(Data(Self.evil.utf8)))
        }
        let long = Array("Dockerfile".utf8) + [0]
        let gnuName = Self.header("././@LongLink", type: "L", size: long.count, gnu: true) + long + [UInt8](repeating: 0, count: 512 - long.count)
        for outcome in try Self.outcomes(Self.pax([("path", "other")]) + gnuName + Self.file("x", Self.evil) + Self.end) {
            #expect(outcome == .found(Data(Self.evil.utf8)))
        }
        // A PAX value holding a newline is one record (parsed by length, not by line).
        for outcome in try Self.outcomes(Self.pax([("path", "Dockerfile\npath=elsewhere")]) + Self.file("x", Self.evil) + Self.file("Dockerfile", Self.allowed) + Self.end) {
            #expect(outcome == .found(Data(Self.allowed.utf8)))
        }
        // GNU format has no prefix field: only ustar's prefix joins the name.
        for outcome in try Self.outcomes(Self.header("Dockerfile", size: hidden.count, prefix: "", gnu: true) + hidden
                                         + [UInt8](repeating: 0, count: 512 - hidden.count) + Self.end) {
            #expect(outcome == .found(Data(Self.allowed.utf8)))
        }
        for outcome in try Self.outcomes(Self.header("Dockerfile", size: hidden.count, prefix: "ci") + hidden
                                         + [UInt8](repeating: 0, count: 512 - hidden.count) + Self.end, dockerfile: "ci/Dockerfile") {
            #expect(outcome == .found(Data(Self.allowed.utf8)))
        }
    }

    @Test func headerOnlyTypesCarryNoDataWhateverTheirSize() throws {
        // A symlink claiming 512 bytes: Go reads the next header right after it, so must the scanner.
        let archive = Self.header("link", type: "2", size: 512, link: "x") + Self.file("Dockerfile", Self.evil) + Self.end
        for outcome in try Self.outcomes(archive) { #expect(outcome == .found(Data(Self.evil.utf8))) }
    }

    @Test func malformedHeadersEndOfArchiveAndTrailingDataAreRefused() throws {
        try Self.expectRefused(Self.header("a", sizeField: "-1") + Self.end, containing: "size")
        try Self.expectRefused(Self.header("a", sizeField: "0000000089") + Self.end, containing: "size")
        try Self.expectRefused(Self.header("a", checksum: 1) + Self.end, containing: "checksum")
        try Self.expectRefused(Self.pax([("size", "-5")]) + Self.header("a") + Self.end, containing: "PAX size")
        try Self.expectRefused(Self.header("PaxHeader", type: "x", size: 12) + Array("99 path=x\n\0\0".utf8) + [UInt8](repeating: 0, count: 500) + Self.end,
                               containing: "PAX")
        // Data after the end-of-archive marker, and a lone zero block followed by an entry.
        try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + Self.end + Self.file("Dockerfile", Self.evil), containing: "after its end-of-archive")
        try Self.expectRefused(Self.file("Dockerfile", Self.allowed) + [UInt8](repeating: 0, count: 512) + Self.file("Dockerfile", Self.evil) + Self.end,
                               containing: "lone zero block")
        // Ending inside an entry.
        try Self.expectRefused(Array(Self.file("Dockerfile", Self.allowed).prefix(600)), containing: "middle of an entry")
        // Zero padding after the marker (the CLI pads to a record) is fine.
        for outcome in try Self.outcomes(Self.file("Dockerfile", Self.allowed) + Self.end + [UInt8](repeating: 0, count: 9216)) {
            #expect(outcome == .found(Data(Self.allowed.utf8)))
        }
    }

    /// A22: whatever the bytes, the scanner returns an outcome; it never traps. Seeded mutations of a real archive
    /// (plain and gzip) and random headers.
    @Test func arbitraryBytesNeverTrap() throws {
        var generator = SplitMix(seed: 0xB311_0C0D)
        let base = Self.pax([("path", "Dockerfile")]) + Self.file("x", Self.allowed) + Self.header("l", type: "2", link: "y")
            + Self.file("app/a.js", String(repeating: "y", count: 2000)) + Self.end
        let compressed = [UInt8](try Self.gzip(Data(base)))
        for round in 0..<3_000 {
            var bytes = round % 3 == 0 ? compressed : base
            for _ in 0..<(1 + Int(generator.next() % 8)) {
                let index = Int(generator.next() % UInt64(bytes.count))
                bytes[index] = UInt8(truncatingIfNeeded: generator.next())
            }
            if round % 5 == 0 { bytes = Array(bytes.prefix(Int(generator.next() % UInt64(bytes.count)))) }
            if round % 7 == 0 {
                // Size, checksum and type fields of the first header overwritten with arbitrary ASCII.
                for index in 124..<157 where bytes.count > 157 { bytes[index] = UInt8(32 + generator.next() % 95) }
            }
            _ = BuildContextScannerTests.scan(Data(bytes), chunk: 1 + Int(generator.next() % 2048))
        }
        for _ in 0..<500 {
            let random = (0..<(512 * Int(1 + generator.next() % 4))).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            _ = BuildContextScannerTests.scan(Data(random), chunk: 97)
        }
    }
}

/// A small deterministic generator (SplitMix64).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
