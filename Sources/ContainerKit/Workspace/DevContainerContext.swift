import CryptoKit
import Darwin
import Foundation
import Synchronization

/// `.dockerignore` matching as Docker's CLI does it (moby/patternmatcher): one pattern per line, `#` comments, `!`
/// re-includes, patterns cleaned and made relative, `*` and `?` within one path element, `**` across elements, `[…]`
/// classes, `\` escapes; the last matching pattern wins, and a pattern matching a parent folder matches what is in it.
public struct DockerIgnore: Sendable {
    struct Pattern: Sendable {
        var regex: NSRegularExpression
        var exclusion: Bool
    }

    let patterns: [Pattern]
    public var hasExclusions: Bool { patterns.contains { $0.exclusion } }
    public var isEmpty: Bool { patterns.isEmpty }

    public init(_ text: String) {
        var patterns: [Pattern] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var exclusion = false
            if line.hasPrefix("!") {
                exclusion = true
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            line = CodeRootPaths.lexicallyNormalized("/" + line).dropFirst().description
            if line.isEmpty { continue }
            guard let regex = try? NSRegularExpression(pattern: Self.regex(line)) else { continue }
            patterns.append(Pattern(regex: regex, exclusion: exclusion))
        }
        self.patterns = patterns
    }

    /// Whether `path` (relative, `/`-separated) is left out of the context.
    public func ignores(_ path: String) -> Bool {
        var parents: [String] = []
        var current = ""
        for part in path.split(separator: "/") {
            current = current.isEmpty ? String(part) : current + "/" + part
            parents.append(current)
        }
        var ignored = false
        for pattern in patterns {
            let matched = parents.contains { candidate in
                pattern.regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
            }
            if matched { ignored = !pattern.exclusion }
        }
        return ignored
    }

    static func regex(_ pattern: String) -> String {
        var output = "^"
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        // `**/`: zero or more folders.
                        index += 1
                        output += "(?:.*/)?"
                    } else {
                        output += ".*"
                    }
                } else {
                    output += "[^/]*"
                }
            case "?":
                output += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("^") || body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    output += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close
                } else {
                    output += "\\["
                }
            case "\\":
                if index + 1 < characters.count {
                    index += 1
                    output += NSRegularExpression.escapedPattern(for: String(characters[index]))
                }
            default:
                output += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return output + "$"
    }
}

/// Per-file content digests keyed by the file's metadata, so a context is re-read only where something changed.
/// Bounded: past `limit` entries it starts over (the next digest reads everything again).
public final class DevContextDigestCache: Sendable {
    struct Key: Hashable, Sendable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modified: Int64
        var changed: Int64
    }

    private let entries = Mutex<[String: (Key, Data)]>([:])
    let limit: Int

    public init(limit: Int = 250_000) { self.limit = limit }

    func digest(path: String, key: Key, compute: () -> Data?) -> Data? {
        if let (cachedKey, digest) = entries.withLock({ $0[path] }), cachedKey == key { return digest }
        guard let digest = compute() else { return nil }
        entries.withLock { entries in
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entries[path] = (key, digest)
        }
        return digest
    }
}

extension DevContainerBuildInputs {
    public static let maxContextFiles = 200_000
    public static let maxContextBytes: Int64 = 4 << 30

    /// The image tag of these inputs (R15): the Dockerfile's bytes, the build arguments and target, and the content of
    /// every file the context sends (`.dockerignore` respected; links hashed as links, never followed). A change to any
    /// file copied into the image gives a new tag, so the image is rebuilt.
    public func tag(projectKey: String, build: DevContainerPlan.Build, cache: DevContextDigestCache) -> Result<String, Problem> {
        switch Self.contextDigest(context, cache: cache) {
        case .failure(let problem): return .failure(problem)
        case .success(let context):
            var hasher = SHA256()
            hasher.update(data: dockerfile)
            hasher.update(data: Data("\n\(build.args.sorted { $0.key < $1.key })\n\(build.target ?? "")\n".utf8))
            hasher.update(data: context)
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12)
            return .success("bellocode-dev-\(projectKey):\(digest)")
        }
    }

    /// The digest of what a build context sends: paths in order, each with its type, permissions and contents.
    public static func contextDigest(_ root: String, cache: DevContextDigestCache) -> Result<Data, Problem> {
        let ignore = (FileManager.default.contents(atPath: root + "/.dockerignore")?.prefix(1 << 20))
            .map { DockerIgnore(String(decoding: $0, as: UTF8.self)) } ?? DockerIgnore("")
        var hasher = SHA256()
        var files = 0
        var bytes: Int64 = 0
        var pending = [""]
        while let relative = pending.popLast() {
            let folder = relative.isEmpty ? root : root + "/" + relative
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            // Reverse-sorted onto the stack: folders are visited in name order.
            var subfolders: [String] = []
            for name in names.sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                let ignored = ignore.ignores(path)
                var info = stat()
                guard lstat(root + "/" + path, &info) == 0 else { continue }
                let type = info.st_mode & S_IFMT
                if type == S_IFDIR {
                    // An ignored folder may still hold re-included files (`!`); otherwise nothing in it is sent.
                    if !ignored || ignore.hasExclusions { subfolders.append(path) }
                    if !ignored { hasher.update(data: Data("d \(path) \(info.st_mode & 0o7777)\n".utf8)) }
                    continue
                }
                if ignored { continue }
                files += 1
                bytes += Int64(info.st_size)
                guard files <= maxContextFiles, bytes <= maxContextBytes else {
                    return .failure(Problem("The dev container's build context sends more than 200 000 files or 4 GiB; add a .dockerignore so only what the image needs is sent."))
                }
                if type == S_IFLNK {
                    var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                    let count = readlink(root + "/" + path, &target, Int(PATH_MAX))
                    let text = count >= 0 ? String(decoding: target[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
                    hasher.update(data: Data("l \(path) \(text)\n".utf8))
                } else if type == S_IFREG {
                    let key = DevContextDigestCache.Key(device: info.st_dev, inode: info.st_ino, size: Int64(info.st_size),
                                                        modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                                                        changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
                    let digest = cache.digest(path: root + "/" + path, key: key) { fileDigest(root + "/" + path) } ?? Data()
                    hasher.update(data: Data("f \(path) \(info.st_mode & 0o7777) ".utf8))
                    hasher.update(data: digest)
                    hasher.update(data: Data("\n".utf8))
                }
            }
            pending.append(contentsOf: subfolders.reversed())
        }
        return .success(Data(hasher.finalize()))
    }

    static func fileDigest(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return Data(hasher.finalize())
    }
}
