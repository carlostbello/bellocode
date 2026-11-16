import Foundation
import UniformTypeIdentifiers

/// A file, image or large text block attached to the prompt. Lives beside the text (shown as a chip), never inside
/// the attributed string, so editing text cannot corrupt attachments and vice versa.
public struct ComposerAttachment: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case image, file, text
    }

    /// Where the bytes are. Files dropped or pasted from Finder stay on disk; pasted images and text are held in memory.
    public enum Content: Hashable, Sendable, Codable {
        case file(URL)
        case data(Data)
        case text(String)
    }

    /// Stable local identity, assigned once when the attachment is created.
    public let id: String
    public var kind: Kind
    public var name: String
    /// MIME type, for example `image/png` or `text/plain`.
    public var mimeType: String
    public var byteCount: Int
    public var content: Content

    public init(id: String = UUID().uuidString, kind: Kind, name: String, mimeType: String, byteCount: Int, content: Content) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.content = content
    }

    /// A file on disk. Reads only its size (a `stat`), not its bytes.
    public static func file(at url: URL) -> ComposerAttachment {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let isImage = type.conforms(to: .image)
        return ComposerAttachment(
            kind: isImage ? .image : .file, name: url.lastPathComponent,
            mimeType: type.preferredMIMEType ?? (values?.isDirectory == true ? "inode/directory" : "application/octet-stream"),
            byteCount: values?.fileSize ?? 0, content: .file(url)
        )
    }

    /// Image bytes from the pasteboard.
    public static func image(_ data: Data, type: UTType, name: String? = nil) -> ComposerAttachment {
        let ext = type.preferredFilenameExtension ?? "png"
        return ComposerAttachment(
            kind: .image, name: name ?? "Pasted image.\(ext)", mimeType: type.preferredMIMEType ?? "image/png",
            byteCount: data.count, content: .data(data)
        )
    }

    /// A large text paste kept out of the prompt body.
    public static func text(_ text: String, name: String? = nil) -> ComposerAttachment {
        let lines = text.reduce(into: 1) { count, character in if character.isNewline { count += 1 } }
        return ComposerAttachment(
            kind: .text, name: name ?? "Pasted text (\(lines) lines).txt", mimeType: "text/plain",
            byteCount: text.utf8.count, content: .text(text)
        )
    }

    /// "1.2 MB", "340 bytes".
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    /// VoiceOver label for the chip.
    public var accessibilityDescription: String {
        let kindName = switch kind {
        case .image: "Image"
        case .file: "File"
        case .text: "Text"
        }
        return "\(kindName) attachment, \(name), \(formattedSize)"
    }

    /// The file URL, when the attachment is a file on disk.
    public var fileURL: URL? {
        if case .file(let url) = content { url } else { nil }
    }
}

/// Limits from T3 Code: up to 100 attachments, images up to 10 MiB (80 MiB together), other files up to 50 MiB.
public struct AttachmentLimits: Hashable, Sendable {
    public var maxCount = 100
    public var maxImageBytes = 10 * 1_048_576
    public var maxTotalImageBytes = 80 * 1_048_576
    public var maxFileBytes = 50 * 1_048_576
    /// A paste of at least this many UTF-8 bytes becomes a text attachment (T3 Code: 32 KiB).
    public var largePasteBytes = 32 * 1024

    public init() {}
}

/// The ordered attachment list for one draft. A value type: undo snapshots it.
public struct AttachmentList: Hashable, Sendable {
    public enum Rejection: Hashable, Sendable, Error {
        case tooMany(limit: Int)
        case tooLarge(name: String, limit: Int)
        case duplicate(name: String)

        public var message: String {
            switch self {
            case .tooMany(let limit): "You can attach up to \(limit) files."
            case .tooLarge(let name, let limit):
                "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
            case .duplicate(let name): "\(name) is already attached."
            }
        }
    }

    public private(set) var items: [ComposerAttachment]
    public var limits: AttachmentLimits

    public init(_ items: [ComposerAttachment] = [], limits: AttachmentLimits = AttachmentLimits()) {
        self.items = items
        self.limits = limits
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Checks one candidate against the list and the limits.
    public func check(_ attachment: ComposerAttachment) -> Rejection? {
        if items.count >= limits.maxCount { return .tooMany(limit: limits.maxCount) }
        if let url = attachment.fileURL, items.contains(where: { $0.fileURL == url }) {
            return .duplicate(name: attachment.name)
        }
        switch attachment.kind {
        case .image:
            if attachment.byteCount > limits.maxImageBytes {
                return .tooLarge(name: attachment.name, limit: limits.maxImageBytes)
            }
            let images = items.filter { $0.kind == .image }.reduce(0) { $0 + $1.byteCount }
            if images + attachment.byteCount > limits.maxTotalImageBytes {
                return .tooLarge(name: attachment.name, limit: limits.maxTotalImageBytes)
            }
        case .file, .text:
            if attachment.byteCount > limits.maxFileBytes {
                return .tooLarge(name: attachment.name, limit: limits.maxFileBytes)
            }
        }
        return nil
    }

    /// Adds what fits and reports what did not. Order is preserved.
    @discardableResult
    public mutating func add(_ candidates: [ComposerAttachment]) -> [Rejection] {
        var rejected: [Rejection] = []
        for candidate in candidates {
            if let rejection = check(candidate) {
                rejected.append(rejection)
            } else {
                items.append(candidate)
            }
        }
        return rejected
    }

    @discardableResult
    public mutating func remove(id: String) -> ComposerAttachment? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func removeAll() { items.removeAll() }
}
