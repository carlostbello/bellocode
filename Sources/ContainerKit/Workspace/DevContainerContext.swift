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

    /// The image tag for a context digest already computed (of a staged copy, A18).
    public func tag(projectKey: String, build: DevContainerPlan.Build, contextDigest context: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: dockerfile)
        hasher.update(data: Data("\n\(build.args.sorted { $0.key < $1.key })\n\(build.target ?? "")\n".utf8))
        hasher.update(data: context)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12)
        return "bellocode-dev-\(projectKey):\(digest)"
    }

    /// A private copy of what the context sends (A18), the folder the build is given: saves in the project after it
    /// was made cannot change what is built, and its digest (hence the tag) is computed from the copy itself.
    public struct StagedContext: Sendable, Equatable {
        public var directory: String
        public var digest: Data

        /// Removes the copy (best effort).
        public func remove() { try? FileManager.default.removeItem(atPath: directory) }
    }

    /// Copies the context's kept files (`.dockerignore` respected, links copied as links, never followed; APFS clones
    /// where possible) into a new private folder under `parent`, then hashes that folder. The context folder must be
    /// the same folder (device and inode) before and after copying, and still inside the project.
    public func stage(projectRoot: String, parent: String = NSTemporaryDirectory()) -> Result<StagedContext, Problem> {
        var before = stat()
        guard lstat(context, &before) == 0, before.st_mode & S_IFMT == S_IFDIR else {
            return .failure(Problem("The dev container was not built: its build context \(context) is not a folder."))
        }
        let directory = (parent as NSString).appendingPathComponent("bellocode-devctx-\(UUID().uuidString)")
        guard mkdir(directory, 0o700) == 0 else {
            return .failure(Problem("The dev container was not built: a private copy of its context could not be made (\(String(cString: strerror(errno))))."))
        }
        let staged = StagedContext(directory: directory, digest: Data())
        if case .failure(let problem) = Self.copyContext(context, into: directory, identity: before, projectRoot: projectRoot) {
            staged.remove()
            return .failure(problem)
        }
        var after = stat()
        guard lstat(context, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              Self.containmentProblem(context: context, dockerfile: projectRoot, projectRoot: projectRoot) == nil,
              CodeRootPaths.canonical(context) == context else {
            staged.remove()
            return .failure(Problem("The dev container was not built: its build context folder was replaced while it was being read."))
        }
        // The digest of the copy, with the copy's own `.dockerignore` (what the builder applies to it).
        switch Self.contextDigest(directory, cache: DevContextDigestCache(limit: 1)) {
        case .failure(let problem):
            staged.remove()
            return .failure(problem)
        case .success(let digest):
            return .success(StagedContext(directory: directory, digest: digest))
        }
    }

    static let contextReplaced = Problem("The dev container was not built: its build context changed while it was being copied.")
    static let copyFailed = Problem("The dev container was not built: copying its context failed.")
    static let contextTooLarge = Problem("The dev container's build context sends more than 200 000 files or 4 GiB; add a .dockerignore so only what the image needs is sent.")

    /// The kept entries of `root` copied into `destination` (which exists), as `contextDigest` walks them.
    ///
    /// AF07: the walk never resolves a path again. The context folder is opened once without following a link and must
    /// be `identity` (the folder that was verified); every folder below it is opened relative to its already open
    /// parent with `O_NOFOLLOW` and must be the folder that was listed; every file is opened the same way, checked on
    /// its descriptor (a regular file, the one listed, its size counted) and cloned or copied from that descriptor. A
    /// folder swapped for a link while the copy runs therefore fails the copy instead of leading outside the project.
    /// When it is done, the opened context folder must still be `root`, inside `projectRoot`. `beforeDescending` (tests)
    /// runs after a folder was listed as one and before it is opened.
    static func copyContext(_ root: String, into destination: String, identity: stat, projectRoot: String,
                            beforeDescending: ((String) -> Void)? = nil) -> Result<Void, Problem> {
        let source = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return .failure(contextReplaced) }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_dev == identity.st_dev, info.st_ino == identity.st_ino else { return .failure(contextReplaced) }
        let target = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { return .failure(copyFailed) }
        defer { close(target) }
        let ignore = readRegularFile(".dockerignore", in: source, limit: 1 << 20)
            .map { DockerIgnore(String(decoding: $0, as: UTF8.self)) } ?? DockerIgnore("")
        var walk = ContextCopy(ignore: ignore, beforeDescending: beforeDescending)
        if case .failure(let problem) = walk.copyFolder(source, into: target, relative: "") { return .failure(problem) }
        // The folder read is still the context, inside the project (not a folder moved there and back meanwhile).
        guard let now = path(of: source), now == root, let project = CodeRootPaths.canonical(projectRoot), CodeRootPaths.inside(now, project) else {
            return .failure(contextReplaced)
        }
        return .success(())
    }

    /// The current path of an open file or folder (`F_GETPATH`).
    static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The bytes of the regular file `name` in the open folder `folder` (or a path, with `AT_FDCWD`), at most `limit`:
    /// nil for a link, a FIFO or a device (opened without following and without blocking; checked on the descriptor).
    static func readRegularFile(_ name: String, in folder: Int32 = AT_FDCWD, limit: Int) -> Data? {
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    /// One copy walk over open folder descriptors (AF07), bounded like `contextDigest`.
    struct ContextCopy {
        let ignore: DockerIgnore
        let beforeDescending: ((String) -> Void)?
        var files = 0
        var bytes: Int64 = 0

        /// The names in an open folder, sorted ("." and ".." left out), as raw bytes and as text.
        static func names(_ folder: Int32) -> [(raw: [CChar], text: String)]? {
            let copy = dup(folder)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                return nil
            }
            defer { closedir(stream) }
            var names: [(raw: [CChar], text: String)] = []
            while let entry = readdir(stream) {
                let raw = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    Array(bytes.prefix(Int(entry.pointee.d_namlen)).map { CChar(bitPattern: $0) }) + [0]
                }
                let text = String(decoding: raw.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if text == "." || text == ".." { continue }
                names.append((raw, text))
            }
            return names.sorted { $0.text < $1.text }
        }

        mutating func copyFolder(_ source: Int32, into target: Int32, relative: String) -> Result<Void, Problem> {
            guard let names = Self.names(source) else { return .failure(DevContainerBuildInputs.contextReplaced) }
            for (raw, name) in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let ignored = ignore.ignores(path)
                var listed = stat()
                guard fstatat(source, raw, &listed, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let type = listed.st_mode & S_IFMT
                if type == S_IFDIR {
                    guard !ignored || ignore.hasExclusions else { continue }
                    beforeDescending?(path)
                    guard mkdirat(target, raw, 0o700) == 0 else { return .failure(DevContainerBuildInputs.copyFailed) }
                    let child = openat(source, raw, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { return .failure(DevContainerBuildInputs.contextReplaced) }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == listed.st_dev, opened.st_ino == listed.st_ino else {
                        return .failure(DevContainerBuildInputs.contextReplaced)
                    }
                    let childTarget = openat(target, raw, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard childTarget >= 0 else { return .failure(DevContainerBuildInputs.copyFailed) }
                    defer { close(childTarget) }
                    if case .failure(let problem) = copyFolder(child, into: childTarget, relative: path) { return .failure(problem) }
                    // Folder permissions as in the context, set once it is filled (a read-only folder must be filled first).
                    fchmod(childTarget, opened.st_mode & 0o7777)
                    continue
                }
                if ignored { continue }
                files += 1
                bytes += Int64(listed.st_size)
                guard files <= maxContextFiles, bytes <= maxContextBytes else { return .failure(DevContainerBuildInputs.contextTooLarge) }
                if type == S_IFLNK {
                    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                    let count = readlinkat(source, raw, &buffer, Int(PATH_MAX))
                    guard count >= 0 else { continue }
                    buffer[count] = 0
                    guard symlinkat(buffer, target, raw) == 0 else { return .failure(DevContainerBuildInputs.copyFailed) }
                } else if type == S_IFREG {
                    if case .failure(let problem) = copyFile(raw, path: path, from: source, into: target, listed: listed) { return .failure(problem) }
                }
            }
            return .success(())
        }

        /// One regular file, from its own descriptor: the file listed (not a link or FIFO swapped in), its size as
        /// opened counted, cloned (blocks shared until either side changes) or copied.
        mutating func copyFile(_ raw: [CChar], path: String, from source: Int32, into target: Int32, listed: stat) -> Result<Void, Problem> {
            let fd = openat(source, raw, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .failure(DevContainerBuildInputs.contextReplaced) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == listed.st_dev, opened.st_ino == listed.st_ino else {
                return .failure(DevContainerBuildInputs.contextReplaced)
            }
            bytes += Int64(opened.st_size) - Int64(listed.st_size)
            guard bytes <= maxContextBytes else { return .failure(DevContainerBuildInputs.contextTooLarge) }
            if fclonefileat(fd, target, raw, 0) != 0 {
                let output = openat(target, raw, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, opened.st_mode & 0o7777)
                guard output >= 0 else { return .failure(Problem("The dev container was not built: copying \(path) from its context failed.")) }
                defer { close(output) }
                guard fcopyfile(fd, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                    return .failure(Problem("The dev container was not built: copying \(path) from its context failed."))
                }
            }
            // What was copied counts (the file may have grown since it was opened).
            var copied = stat()
            if fstatat(target, raw, &copied, AT_SYMLINK_NOFOLLOW) == 0 {
                bytes += Int64(copied.st_size) - Int64(opened.st_size)
                guard bytes <= maxContextBytes else { return .failure(DevContainerBuildInputs.contextTooLarge) }
            }
            return .success(())
        }
    }

    /// The digest of what a build context sends: paths in order, each with its type, permissions and contents.
    public static func contextDigest(_ root: String, cache: DevContextDigestCache) -> Result<Data, Problem> {
        // Never a link followed or a FIFO waited on (AF25): a `.dockerignore` that is not a regular file has no patterns.
        let ignore = readRegularFile(root + "/.dockerignore", limit: 1 << 20)
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
        // Without blocking (AF25): a FIFO swapped in after the listing is refused on the descriptor, never waited on.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
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
