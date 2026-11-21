import Foundation

/// Checks a classic `POST /build` context while it passes through the filtered endpoint (R14, A08, N04, A22). The
/// whole archive is read, headers parsed as the daemon's reader (Go's `archive/tar`, then moby's unpacker) parses
/// them, and only the Dockerfile's contents are kept (at most 1 MiB). The proxy holds the context back until
/// `finish()` has judged all of it, so the daemon only ever receives an archive whose effective Dockerfile was checked.
///
/// Refused rather than interpreted (never a trap: every size is validated before it is used):
/// - a second entry for the Dockerfile's path (the unpacker lets the last one win), or a Dockerfile entry that is not
///   a regular file (link, directory, device);
/// - an entry written through a link entry earlier in the archive (`d -> .`, then `d/Dockerfile`), and a link entry
///   at the Dockerfile's path or any folder above it (the daemon follows links in scope when it opens the Dockerfile);
/// - names that leave the context (`../x`), sparse files, malformed numbers or PAX records, bad header checksums,
///   data after the end-of-archive marker;
/// - gzip that is not valid, truncated, or followed by bytes that are not another gzip member (concatenated members
///   are decoded, as Go's reader does); bzip2, xz and zstd.
///
/// ustar names with prefixes (and the star variant), GNU long names (`L`), PAX `path` and `size` records are understood
/// with Go's precedence (a GNU long name wins over a PAX path; a PAX `size` replaces the header's), and header-only
/// entry types (links, devices, folders, FIFOs) carry no data whatever their size field says.
struct BuildContextScanner {
    enum Outcome: Equatable {
        case found(Data)
        case missing
        case refused(String)
    }

    static let dockerfileLimit = 1 << 20
    /// Go refuses special files (PAX records, GNU long names) above 1 MiB.
    static let specialFileLimit = 1 << 20
    /// Entry sizes above this are refused (also keeps padding arithmetic far from overflow).
    static let maxEntrySize = 1 << 40
    static let maxEntries = 2_000_000
    static let maxLinks = 200_000

    private enum State {
        case header
        case skip(Int)
        case capture(remaining: Int, padding: Int, kind: Capture)
        /// One zero block seen: the next block must be zero too (Go's end-of-archive rule).
        case endMarker
        /// After the end-of-archive marker: only zero bytes may follow.
        case trailing
    }

    private enum Capture { case dockerfile, longName, longLink, pax, globalPax }

    let target: String
    private let targetProblem: String?
    private var state = State.header
    private var buffer = Data()
    private var captured = Data()
    private var longName: String?
    private var pax: [String: String]?
    private var format = Format.unknown
    private var sniffed = Data()
    private var dockerfile: Data?
    private var links = Set<String>()
    private var entries = 0
    private var refusal: String?

    private enum Format {
        case unknown
        case tar
        case gzip(GzipInflater)
    }

    init(dockerfile: String?) {
        let requested = dockerfile.flatMap { $0.isEmpty ? nil : $0 } ?? "Dockerfile"
        if let normalised = Self.normalise(requested), !normalised.isEmpty {
            target = normalised
            targetProblem = nil
        } else {
            target = requested
            targetProblem = "the Dockerfile path “\(requested)” leaves the build context."
        }
    }

    /// The path an entry is unpacked at, relative to the context (moby cleans names and refuses those that leave the
    /// destination), or nil when it leaves the context.
    static func normalise(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    /// Feeds the next bytes of the body. Returns a refusal as soon as one is certain, else nil: the Dockerfile is only
    /// known to be the effective one at the end (`finish()`).
    mutating func feed(_ data: Data) -> Outcome? {
        if let refusal { return .refused(refusal) }
        if let targetProblem { return refuse(targetProblem) }
        switch format {
        case .unknown:
            // The format is known from the first six bytes, whatever the chunking.
            sniffed.append(data)
            guard sniffed.count >= 6 else { return nil }
            let first = sniffed
            sniffed = Data()
            let magic = [UInt8](first.prefix(6))
            if magic.starts(with: [0x1f, 0x8b]) {
                format = .gzip(GzipInflater())
            } else if magic.starts(with: [0x42, 0x5a, 0x68]) || magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a])
                        || magic.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
                return refuse("bzip2, xz and zstd compressed build contexts cannot be checked; build without --compress.")
            } else {
                format = .tar
            }
            return feed(first)
        case .tar:
            feedTar(data)
        case .gzip(let inflater):
            do {
                try inflater.feed(data) { piece in
                    feedTar(piece)
                    return refusal == nil
                }
            } catch {
                return refuse("the compressed build context is not valid gzip, so its Dockerfile cannot be checked.")
            }
        }
        return refusal.map { .refused($0) }
    }

    @discardableResult
    private mutating func refuse(_ reason: String) -> Outcome {
        if refusal == nil { refusal = reason }
        return .refused(refusal!)
    }

    /// The tar archive's next bytes (decompressed already).
    private mutating func feedTar(_ data: Data) {
        guard refusal == nil else { return }
        buffer.append(data)
        while refusal == nil {
            switch state {
            case .trailing:
                if buffer.contains(where: { $0 != 0 }) {
                    refuse("the build context has data after its end-of-archive marker.")
                }
                buffer.removeAll(keepingCapacity: true)
                return
            case .skip(let remaining):
                let count = min(remaining, buffer.count)
                buffer.removeFirst(count)
                if count < remaining { state = .skip(remaining - count); return }
                state = .header
            case .capture(let remaining, let padding, let kind):
                let count = min(remaining, buffer.count)
                captured.append(buffer.prefix(count))
                buffer.removeFirst(count)
                if count < remaining { state = .capture(remaining: remaining - count, padding: padding, kind: kind); return }
                switch kind {
                case .dockerfile:
                    dockerfile = captured
                case .longName:
                    longName = String(decoding: captured.prefix { $0 != 0 }, as: UTF8.self)
                case .longLink:
                    break
                case .pax:
                    // A second extended header replaces the first (Go keeps only the latest).
                    guard let records = Self.paxRecords(captured) else {
                        refuse("the build context has a malformed PAX header.")
                        return
                    }
                    if records.keys.contains(where: { $0.hasPrefix("GNU.sparse.") }) {
                        refuse("the build context holds a sparse file, which BelloCode does not unpack the way Docker does.")
                        return
                    }
                    pax = records
                case .globalPax:
                    guard Self.paxRecords(captured) != nil else {
                        refuse("the build context has a malformed PAX header.")
                        return
                    }
                }
                captured = Data()
                state = .skip(padding)
            case .endMarker:
                guard buffer.count >= 512 else { return }
                let block = buffer.prefix(512)
                guard block.allSatisfy({ $0 == 0 }) else {
                    refuse("the build context has a lone zero block followed by more entries.")
                    return
                }
                buffer.removeFirst(512)
                state = .trailing
            case .header:
                guard buffer.count >= 512 else { return }
                let header = [UInt8](buffer.prefix(512))
                buffer.removeFirst(512)
                if header.allSatisfy({ $0 == 0 }) {
                    state = .endMarker
                    continue
                }
                entry(header)
            }
        }
    }

    /// One 512-byte header that is not a zero block.
    private mutating func entry(_ header: [UInt8]) {
        guard Self.checksumValid(header) else {
            refuse("the build context is not a tar archive BelloCode can read (bad header checksum).")
            return
        }
        guard let rawSize = Self.octal(header[124..<136]) else {
            refuse("the build context is not a tar archive BelloCode can read (bad size field).")
            return
        }
        entries += 1
        guard entries <= Self.maxEntries else {
            refuse("the build context has more than \(Self.maxEntries) entries.")
            return
        }
        let type = header[156]
        switch type {
        case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"), UInt8(ascii: "g"):
            guard rawSize <= Self.specialFileLimit else {
                refuse("a header in the build context is too large.")
                return
            }
            let kind: Capture = switch type {
            case UInt8(ascii: "L"): .longName
            case UInt8(ascii: "K"): .longLink
            case UInt8(ascii: "x"): .pax
            default: .globalPax
            }
            if kind == .globalPax {
                // Go returns a global header as an entry of its own: what was pending for the next entry is dropped.
                pax = nil
                longName = nil
            }
            state = .capture(remaining: rawSize, padding: Self.padding(rawSize), kind: kind)
            return
        case UInt8(ascii: "S"):
            refuse("the build context holds a sparse file, which BelloCode does not unpack the way Docker does.")
            return
        default:
            break
        }
        // The entry itself: Go merges the pending PAX records, then applies a GNU long name over them.
        var name = Self.headerName(header)
        var size = rawSize
        if let pax {
            if let path = pax["path"] { name = path }
            if let text = pax["size"] {
                guard let value = Int(text), value >= 0, value <= Self.maxEntrySize, text.allSatisfy(\.isASCII) else {
                    refuse("the build context has a malformed PAX size.")
                    return
                }
                size = value
            }
        }
        if let longName { name = longName }
        pax = nil
        longName = nil
        // A plain (V7) entry whose name ends in "/" is a folder to Go.
        let effectiveType: UInt8 = (type == 0 && name.hasSuffix("/")) ? UInt8(ascii: "5") : type
        guard let path = Self.normalise(name) else {
            refuse("the build context has an entry that leaves the context (“\(name.prefix(200))”).")
            return
        }
        // Written through a link an earlier entry made: the unpacker would put it somewhere else than its name says.
        var ancestor = ""
        for component in path.split(separator: "/").dropLast() {
            ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
            if links.contains(ancestor) {
                refuse("the build context has an entry (“\(path.prefix(200))”) inside a link (“\(ancestor.prefix(200))”).")
                return
            }
        }
        let isLink = effectiveType == UInt8(ascii: "1") || effectiveType == UInt8(ascii: "2")
        if isLink {
            if path == target || target.hasPrefix(path + "/") || path.isEmpty {
                refuse("the build context's Dockerfile path “\(target)” passes through a link, so the file Docker builds cannot be checked.")
                return
            }
            if effectiveType == UInt8(ascii: "2") {
                links.insert(path)
                guard links.count <= Self.maxLinks else {
                    refuse("the build context has more than \(Self.maxLinks) links.")
                    return
                }
            }
        }
        let isRegular = effectiveType == UInt8(ascii: "0") || effectiveType == 0 || effectiveType == UInt8(ascii: "7")
        // Header-only types carry no data in Go's reader, whatever their size field says.
        let headerOnly = [UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"), UInt8(ascii: "4"), UInt8(ascii: "5"), UInt8(ascii: "6")]
            .contains(effectiveType)
        let dataSize = headerOnly ? 0 : size
        if path == target {
            guard dockerfile == nil else {
                refuse("the build context has more than one entry for its Dockerfile “\(target)”; Docker would build the last one.")
                return
            }
            guard isRegular, effectiveType != UInt8(ascii: "7") else {
                refuse("the build context's Dockerfile “\(target)” is not a regular file.")
                return
            }
            guard dataSize <= Self.dockerfileLimit else {
                refuse("the Dockerfile is larger than 1 MiB.")
                return
            }
            captured = Data()
            state = .capture(remaining: dataSize, padding: Self.padding(dataSize), kind: .dockerfile)
            return
        }
        state = .skip(dataSize + Self.padding(dataSize))
    }

    /// The end of the body: judged only now, once nothing after the Dockerfile can replace it.
    mutating func finish() -> Outcome {
        if let refusal { return .refused(refusal) }
        if let targetProblem { return refuse(targetProblem) }
        if case .unknown = format, !sniffed.isEmpty {
            format = .tar
            feedTar(sniffed)
            sniffed = Data()
            if let refusal { return .refused(refusal) }
        }
        if case .gzip(let inflater) = format, !inflater.atMemberBoundary {
            return refuse("the compressed build context ended in the middle of a gzip member.")
        }
        switch state {
        case .header where buffer.isEmpty, .endMarker where buffer.isEmpty, .trailing:
            break
        default:
            return refuse("the build context ended in the middle of an entry.")
        }
        guard let dockerfile else { return .missing }
        return .found(dockerfile)
    }

    static func padding(_ size: Int) -> Int { (512 - size % 512) % 512 }

    /// Go's checksum rule: the header's bytes summed with the checksum field as spaces, unsigned or signed.
    static func checksumValid(_ header: [UInt8]) -> Bool {
        guard let recorded = octal(header[148..<156]) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in header.enumerated() {
            let value = (148..<156).contains(index) ? 0x20 : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return recorded == unsigned || recorded == signed
    }

    static func headerName(_ header: [UInt8]) -> String {
        func field(_ range: Range<Int>) -> String { String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self) }
        let name = field(0..<100)
        let magic = Array(header[257..<263])
        let isUstar = magic == Array("ustar".utf8) + [0]
        let isStar = isUstar && Array(header[508..<512]) == Array("tar".utf8) + [0]
        let prefix = isStar ? field(345..<476) : isUstar ? field(345..<500) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    /// Go's `parseOctal`: leading and trailing spaces and NULs trimmed, cut at the first NUL, octal digits only.
    /// Base-256 numbers (high bit set, only used above 8 GiB) and anything negative or malformed are refused.
    static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        if let first = bytes.first, first & 0x80 != 0 { return nil }
        var trimmed = bytes
        while let first = trimmed.first, first == 0x20 || first == 0 { trimmed = trimmed.dropFirst() }
        while let last = trimmed.last, last == 0x20 || last == 0 { trimmed = trimmed.dropLast() }
        let digits = trimmed.prefix { $0 != 0 }
        if digits.isEmpty { return 0 }
        var value = 0
        for digit in digits {
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7") else { return nil }
            value = value * 8 + Int(digit - UInt8(ascii: "0"))
            guard value <= maxEntrySize else { return nil }
        }
        return value
    }

    /// PAX extended-header records (`<length> <key>=<value>\n`, the length counting the whole record), parsed by
    /// length as Go does; nil when malformed.
    static func paxRecords(_ data: Data) -> [String: String]? {
        var records: [String: String] = [:]
        var rest = [UInt8](data)[...]
        while !rest.isEmpty {
            guard let space = rest.firstIndex(of: 0x20) else { return nil }
            let lengthText = rest[rest.startIndex..<space]
            guard !lengthText.isEmpty, lengthText.count <= 10, lengthText.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let length = Int(String(decoding: lengthText, as: UTF8.self)), length > lengthText.count + 1, length <= rest.count
            else { return nil }
            let record = rest[rest.startIndex..<(rest.startIndex + length)]
            rest = rest[(rest.startIndex + length)...]
            guard record.last == 0x0a else { return nil }
            let body = record[(space + 1)..<(record.endIndex - 1)]
            guard let equals = body.firstIndex(of: UInt8(ascii: "=")), equals > body.startIndex else { return nil }
            let key = String(decoding: body[body.startIndex..<equals], as: UTF8.self)
            let valueBytes = body[(equals + 1)...]
            if ["path", "linkpath", "uname", "gname"].contains(key), valueBytes.contains(0) { return nil }
            records[key] = String(decoding: valueBytes, as: UTF8.self)
        }
        return records
    }
}
