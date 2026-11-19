import Foundation

/// Finds the Dockerfile in a classic `POST /build` context while it streams through the filtered endpoint (R14): the
/// body is a tar; headers are parsed as bytes pass, only the Dockerfile's contents are kept (at most 1 MiB), nothing
/// else is buffered. ustar names with prefixes, GNU long names (`L`) and PAX `path` records are understood. Compressed
/// contexts are refused (the CLI sends plain tar unless `--compress` is given).
struct BuildContextScanner {
    enum Outcome: Equatable {
        case found(Data)
        case missing
        case refused(String)
    }

    static let dockerfileLimit = 1 << 20

    private enum State {
        case header
        case skip(Int)
        case capture(remaining: Int, padding: Int, kind: Capture)
        case done
    }

    private enum Capture { case dockerfile, longName, pax }

    let target: String
    private var state = State.header
    private var buffer = Data()
    private var captured = Data()
    private var nextName: String?
    private var started = false
    private(set) var outcome: Outcome?

    init(dockerfile: String?) {
        target = Self.normalise(dockerfile.flatMap { $0.isEmpty ? nil : $0 } ?? "Dockerfile")
    }

    static func normalise(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }.joined(separator: "/")
    }

    /// Feeds the next bytes of the body; returns the outcome once known (then ignores further bytes).
    mutating func feed(_ data: Data) -> Outcome? {
        guard outcome == nil else { return outcome }
        if !started, !data.isEmpty {
            started = true
            let magic = [UInt8](data.prefix(6))
            if magic.starts(with: [0x1f, 0x8b]) || magic.starts(with: [0x42, 0x5a, 0x68]) || magic.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a]) {
                outcome = .refused("compressed build contexts cannot be checked; build without --compress.")
                return outcome
            }
        }
        buffer.append(data)
        while outcome == nil {
            switch state {
            case .done:
                return outcome
            case .skip(let remaining):
                let count = min(remaining, buffer.count)
                buffer.removeFirst(count)
                if count < remaining { state = .skip(remaining - count); return nil }
                state = .header
            case .capture(let remaining, let padding, let kind):
                let count = min(remaining, buffer.count)
                captured.append(buffer.prefix(count))
                buffer.removeFirst(count)
                if count < remaining { state = .capture(remaining: remaining - count, padding: padding, kind: kind); return nil }
                switch kind {
                case .dockerfile:
                    outcome = .found(captured)
                    state = .done
                    return outcome
                case .longName:
                    nextName = String(decoding: captured.prefix { $0 != 0 }, as: UTF8.self)
                case .pax:
                    if let path = Self.paxPath(captured) { nextName = path }
                }
                captured = Data()
                state = .skip(padding)
            case .header:
                guard buffer.count >= 512 else { return nil }
                let header = [UInt8](buffer.prefix(512))
                buffer.removeFirst(512)
                if header.allSatisfy({ $0 == 0 }) {
                    outcome = .missing
                    state = .done
                    return outcome
                }
                guard let size = Self.octal(header[124..<136]) else {
                    outcome = .refused("the build context is not a tar archive BelloCode can read.")
                    return outcome
                }
                let padded = (size + 511) / 512 * 512
                let type = header[156]
                let name = nextName ?? Self.headerName(header)
                switch type {
                case UInt8(ascii: "L"):
                    guard size <= 64 * 1024 else { outcome = .refused("a name in the build context is too long."); return outcome }
                    state = .capture(remaining: size, padding: padded - size, kind: .longName)
                    continue
                case UInt8(ascii: "x"):
                    guard size <= 64 * 1024 else { outcome = .refused("a header in the build context is too large."); return outcome }
                    state = .capture(remaining: size, padding: padded - size, kind: .pax)
                    continue
                default:
                    break
                }
                nextName = nil
                if type == UInt8(ascii: "0") || type == 0, Self.normalise(name) == target {
                    guard size <= Self.dockerfileLimit else {
                        outcome = .refused("the Dockerfile is larger than 1 MiB.")
                        return outcome
                    }
                    state = .capture(remaining: size, padding: padded - size, kind: .dockerfile)
                } else {
                    state = .skip(padded)
                }
            }
        }
        return outcome
    }

    /// The end of the body: the archive ended without the Dockerfile unless it was found.
    mutating func finish() -> Outcome {
        if let outcome { return outcome }
        outcome = .missing
        return .missing
    }

    static func headerName(_ header: [UInt8]) -> String {
        func field(_ range: Range<Int>) -> String { String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self) }
        let name = field(0..<100)
        let isUstar = header[257..<262].elementsEqual(Array("ustar".utf8))
        let prefix = isUstar ? field(345..<500) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    static func octal(_ bytes: ArraySlice<UInt8>) -> Int? {
        // Base-256 (high bit set) sizes are only used above 8 GiB: refuse them.
        if let first = bytes.first, first & 0x80 != 0 { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        return Int(text, radix: 8)
    }

    /// `path=` from PAX extended-header records (`<length> <key>=<value>\n`).
    static func paxPath(_ data: Data) -> String? {
        var path: String?
        for record in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let pair = record[record.index(after: space)...]
            if pair.hasPrefix("path=") { path = String(pair.dropFirst(5)) }
        }
        return path
    }
}
