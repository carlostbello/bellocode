import BelloCore
import CryptoKit
import Foundation
import Observation

/// One render of an HTML document in the sandbox (BrowserKit `HTMLVisualRenderer` implements it).
public struct HTMLRenderRequest: Sendable, Hashable {
    public var html: String
    /// Hosts the content may load from (already approved). Empty: no network at all.
    public var allowedHosts: [String]
    public var dark: Bool
    /// CSS pixels.
    public var width: Double

    public init(html: String, allowedHosts: [String] = [], dark: Bool = false, width: Double = 720) {
        self.html = html
        self.allowedHosts = allowedHosts
        self.dark = dark
        self.width = width
    }
}

public struct HTMLRenderOutput: Sendable {
    /// The document's height in CSS pixels (uncapped).
    public var contentHeight: Double
    /// PNG of the visible part (capped height).
    public var png: Data?
    /// `console.error`/`console.warn` lines and uncaught errors (bounded).
    public var console: [String]
    /// Requests the sandbox refused (network, frames, navigation), bounded.
    public var blocked: [String]

    public init(contentHeight: Double, png: Data?, console: [String] = [], blocked: [String] = []) {
        self.contentHeight = contentHeight
        self.png = png
        self.console = console
        self.blocked = blocked
    }
}

@MainActor
public protocol HTMLVisualRendering: AnyObject {
    func render(_ request: HTMLRenderRequest) async throws -> HTMLRenderOutput
}

/// What BelloCode keeps of a visual (`<id>.json` beside `<id>.html` in the visuals folder). No secrets, no network
/// grants beyond host names.
public struct VisualRecord: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var sessionID: SessionID
    public var requestedHosts: [String]
    /// Hosts approved for this visual only ("Allow Once").
    public var approvedHosts: [String]
    public var contentHeight: Double
    public var created: Date
}

/// HTML visual replies (docs/features/orchestration-extras.md): `html_preview` (check a page: height, console, blocked
/// requests, a PNG) and `html_render` (show it inline in the transcript). Documents are kept in the app's cache folder
/// (bounded, newest `maxVisuals`); rendering is delegated to the sandboxed WebKit renderer the app provides. Network is
/// off unless the call asks for hosts and the person approves them (once for this visual, or always for those hosts).
@MainActor
@Observable
public final class VisualService {
    /// Bumps when a visual's network grant changes (live views reload).
    public private(set) var revision = 0

    public static let maxVisuals = 300
    public static let maxHTMLBytes = 2 << 20
    public static let previewWidth: Double = 720

    @ObservationIgnored public weak var renderer: (any HTMLVisualRendering)?
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let store: ProjectionStore
    @ObservationIgnored private var grantedHosts: Set<String> = []
    @ObservationIgnored private var records: [String: VisualRecord] = [:]

    public init(store: ProjectionStore, directory: URL? = nil) {
        self.store = store
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BelloCode/visuals", directoryHint: .isDirectory)
    }

    public func load() async {
        grantedHosts = (try? await store.grants(.network)) ?? []
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Reads (the app's views and image loader)

    public func record(_ id: String) -> VisualRecord? {
        if let record = records[id] { return record }
        guard Self.isValidID(id), let data = try? Data(contentsOf: directory.appending(path: "\(id).json")),
            let record = try? JSONDecoder().decode(VisualRecord.self, from: data)
        else { return nil }
        records[id] = record
        return record
    }

    public func html(_ id: String) -> String? {
        guard Self.isValidID(id) else { return nil }
        return try? String(contentsOf: directory.appending(path: "\(id).html"), encoding: .utf8)
    }

    /// Hosts this visual may load from now: requested ones that are approved (always, or once for this visual).
    public func allowedHosts(_ id: String) -> [String] {
        guard let record = record(id) else { return [] }
        return record.requestedHosts.filter { grantedHosts.contains($0) || record.approvedHosts.contains($0) }
    }

    public func blockedHosts(_ id: String) -> [String] {
        guard let record = record(id) else { return [] }
        let allowed = Set(allowedHosts(id))
        return record.requestedHosts.filter { !allowed.contains($0) }
    }

    /// A snapshot PNG for the transcript (cached per scheme until the grant changes).
    public func snapshot(_ id: String, dark: Bool) async -> Data? {
        let file = directory.appending(path: "\(id)-\(dark ? "dark" : "light").png")
        if let data = try? Data(contentsOf: file) { return data }
        guard let html = html(id), let renderer else { return nil }
        guard let output = try? await renderer.render(HTMLRenderRequest(html: html, allowedHosts: allowedHosts(id), dark: dark, width: Self.previewWidth)),
            let png = output.png
        else { return nil }
        try? png.write(to: file, options: .atomic)
        return png
    }

    /// Writes a PNG of the visual next to the others and returns its URL ("Save Image" copies it).
    public func exportPNG(_ id: String, dark: Bool) async -> URL? {
        guard await snapshot(id, dark: dark) != nil else { return nil }
        return directory.appending(path: "\(id)-\(dark ? "dark" : "light").png")
    }

    // MARK: Tools

    /// Resolves `html` or `path` into a document. A path (absolute, or relative to the thread's directory) must name
    /// a regular file inside one of `roots` (the calling thread's project and worktree folders) after resolving
    /// symlinks and `..`; it is opened once and read with a size cap from that descriptor (S6 in
    /// docs/reviews/deep-review-1.md). Anything else is refused with a tool error.
    func document(html: String?, path: String?, directory base: String, roots: [String]) throws -> String {
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard html.utf8.count <= Self.maxHTMLBytes else { throw ExtrasError("The HTML is larger than 2 MB.") }
            return html
        }
        guard let path, !path.isEmpty else { throw ExtrasError("Give html (the document) or path (an .html file).") }
        return try Self.readAuthorisedFile(path, base: base, roots: roots, limit: Self.maxHTMLBytes)
    }

    /// Reads a UTF-8 file that resolves inside `roots`, at most `limit` bytes, from a single descriptor.
    nonisolated static func readAuthorisedFile(_ path: String, base: String, roots: [String], limit: Int) throws -> String {
        let candidate = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        let realRoots = roots.compactMap(Self.realPath)
        func inside(_ resolved: String) -> Bool {
            realRoots.contains { resolved == $0 || resolved.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        let outside = ExtrasError("\(path) is outside this thread's project and worktree folders; visuals read files only from there. Pass the HTML inline instead.")
        guard let resolved = Self.realPath(candidate) else { throw ExtrasError("No file at \(candidate).") }
        guard inside(resolved) else { throw outside }
        let fd = open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ExtrasError("\(path) could not be opened.") }
        defer { close(fd) }
        // The descriptor is what is read: check what it actually is and where it actually lives (a folder swapped for
        // a symlink after resolving is caught here).
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ExtrasError("\(path) is not a regular file.") }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw ExtrasError("\(path) could not be opened.") }
        guard let opened = Self.realPath(String(cString: buffer)), inside(opened) else { throw outside }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ExtrasError("\(path) could not be read.")
            }
            if count == 0 { break }
            data.append(contentsOf: chunk[0..<count])
            guard data.count <= limit else { throw ExtrasError("The file is larger than \(limit >= 1 << 20 ? "\(limit >> 20) MB" : "\(limit) bytes").") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ExtrasError("The file is not UTF-8 text.") }
        return text
    }

    /// `html_preview`: renders once (light), returns the facts the agent needs and a PNG path it may share.
    func preview(html: String, hosts: [String]) async throws -> String {
        guard let renderer else { throw ExtrasError("BelloCode cannot render visuals right now.") }
        let allowed = hosts.filter(grantedHosts.contains)
        let output = try await renderer.render(HTMLRenderRequest(html: html, allowedHosts: allowed, dark: false, width: Self.previewWidth))
        let previews = directory.appending(path: "previews", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var lines = [
            "contentHeight: \(Int(output.contentHeight.rounded())) (shown up to \(Int(VisualCardContentLimits.maxHeight)); taller content scrolls inside the visual)",
            "width: \(Int(Self.previewWidth))",
        ]
        if let png = output.png {
            let file = previews.appending(path: UUID().uuidString.lowercased() + ".png")
            try png.write(to: file, options: .atomic)
            lines.append("png: \(file.path)")
        }
        lines.append(output.console.isEmpty ? "console: (no errors or warnings)" : "console:\n" + output.console.prefix(20).map { "  " + $0 }.joined(separator: "\n"))
        if !output.blocked.isEmpty {
            lines.append("blocked (no network by default; ask for hosts with allowNetwork in html_render):\n" + output.blocked.prefix(20).map { "  " + $0 }.joined(separator: "\n"))
    nonisolated static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

        }
        if !hosts.isEmpty, allowed.count < hosts.count {
            lines.append("network: previews load only hosts already approved; html_render asks the user for the others.")
        }
        return lines.joined(separator: "\n")
    }

    /// `html_render`: stores the document, renders it once to measure it (and for the PNG export), and returns the
    /// lines the transcript row reads (`visualID:`, `height:`, `note:`). Hosts not yet approved raise an approval.
    func render(html: String, title: String, hosts: [String], sessionID: SessionID) async throws -> (text: String, id: String, needsApproval: [String]) {
        guard let renderer else { throw ExtrasError("BelloCode cannot render visuals right now.") }
        let id = Self.makeID(html: html, title: title, sessionID: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try html.write(to: directory.appending(path: "\(id).html"), atomically: true, encoding: .utf8)
        var record = record(id) ?? VisualRecord(
            id: id, title: title, sessionID: sessionID, requestedHosts: [], approvedHosts: [], contentHeight: 0, created: Date())
        record.requestedHosts = hosts
        records[id] = record
        let allowed = allowedHosts(id)
        let output = try await renderer.render(HTMLRenderRequest(html: html, allowedHosts: allowed, dark: false, width: Self.previewWidth))
        record.contentHeight = output.contentHeight
        records[id] = record
        try JSONEncoder().encode(record).write(to: directory.appending(path: "\(id).json"), options: .atomic)
        if let png = output.png { try? png.write(to: directory.appending(path: "\(id)-light.png"), options: .atomic) }
        prune()
        let pending = hosts.filter { !allowed.contains($0) }
        var lines = [
            "visualID: \(id)", "height: \(Int(min(VisualCardContentLimits.maxHeight, max(60, output.contentHeight)).rounded()))",
        ]
        if !pending.isEmpty { lines.append("note: Network blocked until the user approves \(pending.joined(separator: ", "))") }
        lines.append("png: \(directory.appending(path: "\(id)-light.png").path)")
        if !output.console.isEmpty { lines.append("console: " + output.console.prefix(5).joined(separator: " | ")) }
        lines.append("Shown to the user inline in this thread. Do not repeat its content in your reply.")
        return (lines.joined(separator: "\n"), id, pending)
    }

    /// The person's answer to a network approval.
    func approveNetwork(_ id: String, hosts: [String], always: Bool) async {
        if always {
            for host in hosts {
                try? await store.setGrant(.network, scope: host, granted: true)
                grantedHosts.insert(host)
            }
            revision += 1
        } else if var record = record(id) {
            record.approvedHosts = Array(Set(record.approvedHosts).union(hosts)).sorted()
            records[id] = record
            try? JSONEncoder().encode(record).write(to: directory.appending(path: "\(id).json"), options: .atomic)
        }
        for scheme in ["light", "dark"] { try? FileManager.default.removeItem(at: directory.appending(path: "\(id)-\(scheme).png")) }
        revision += 1
    }

    public var networkGrants: [String] {
        _ = revision
        return grantedHosts.sorted()
    }

    public func revokeNetwork(_ host: String) async {
        try? await store.setGrant(.network, scope: host, granted: false)
        grantedHosts.remove(host)
        revision += 1
    }

    // MARK: Helpers

    static func makeID(html: String, title: String, sessionID: SessionID) -> String {
        let digest = SHA256.hash(data: Data((sessionID.rawValue + "\n" + title + "\n" + html).utf8))
        return "v_" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("v_") && id.count == 22 && id.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    /// Hosts from the tool's `allowNetwork`: bare host names only (no scheme, path, wildcard or private address).
    static func validHosts(_ raw: [String]) throws -> [String] {
        var hosts: [String] = []
        for value in raw.prefix(8) {
            let host = value.trimmingCharacters(in: .whitespaces).lowercased()
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), host.contains("."), !host.hasPrefix("."),
                host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
                !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) })
            else { throw ExtrasError("allowNetwork takes public host names like cdn.jsdelivr.net (no schemes, paths, IP addresses or local hosts): \(value)") }
            if !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// Keeps the newest `maxVisuals` documents.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let documents = files.filter { $0.pathExtension == "html" }
        guard documents.count > Self.maxVisuals else { return }
        let sorted = documents.sorted {
            (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate ?? .distantPast) ?? .distantPast
        }
        for old in sorted.dropFirst(Self.maxVisuals) {
            let id = old.deletingPathExtension().lastPathComponent
            for suffix in [".html", ".json", "-light.png", "-dark.png"] { try? FileManager.default.removeItem(at: directory.appending(path: id + suffix)) }
            records[id] = nil
        }
    }
}

/// The transcript's cap (TranscriptKit `VisualCardContent.maxHeight`), repeated here because Engine does not import it.
public enum VisualCardContentLimits {
    public static let maxHeight: Double = 480
}
