import Foundation

/// The numeric user a workspace container runs as (AF10). A name (a dev container's `remoteUser`) is resolved from the
/// exact image's `/etc/passwd` and `/etc/group`, read through the engine's archive endpoint from a container that is
/// created but never started, so no program of the image runs before the user is known not to be root. The workspace is
/// then created with the numbers, and a container whose user is not a nonzero number is never reused or adopted.
public struct WorkspaceUser: Sendable, Equatable {
    public var uid: Int
    /// Nil only for a number given without a group: Docker then picks the group, as it always did.
    public var gid: Int?

    public init(uid: Int, gid: Int?) {
        self.uid = uid
        self.gid = gid
    }

    /// `uid` or `uid:gid`: what the container is created with and what `$HOME` belongs to.
    public var numeric: String { gid.map { "\(uid):\($0)" } ?? "\(uid)" }

    /// `user[:group]`, trimmed.
    static func parts(_ value: String) -> (user: String, group: String?) {
        let pieces = value.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return (pieces.first.map(String.init) ?? "", pieces.count == 2 ? String(pieces[1]) : nil)
    }

    /// A decimal number (ASCII digits only, at most a 32-bit id), or nil.
    static func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 10, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), value <= Int(UInt32.max) else {
            return nil
        }
        return value
    }

    /// The user when `value` is numbers only (`uid` or `uid:gid`), with no account lookup; nil when a part is a name.
    public static func numeric(_ value: String) -> WorkspaceUser? {
        let (user, group) = parts(value)
        guard let uid = number(user) else { return nil }
        guard let group else { return WorkspaceUser(uid: uid, gid: nil) }
        guard let gid = number(group) else { return nil }
        return WorkspaceUser(uid: uid, gid: gid)
    }

    /// Whether a container's configured user (`Config.User`) is a nonzero numeric uid: what every workspace container
    /// BelloCode creates has, and what a container must have to be reused or adopted.
    public static func isVerifiedContainerUser(_ value: String?) -> Bool {
        guard let value, let user = numeric(value) else { return false }
        return user.uid != 0
    }

    /// Resolves `value` as Docker (runc) does from the image's account files: a numeric user is a uid (its primary
    /// group from `/etc/passwd` when it has an entry and no group is given), a name is the first `/etc/passwd` entry
    /// of that name; a group is a number or the first `/etc/group` entry of that name. Nil when a name is not found.
    public static func resolve(_ value: String, passwd: String?, group: String?) -> WorkspaceUser? {
        let (userPart, groupPart) = parts(value)
        guard !userPart.isEmpty else { return nil }
        let entries = (passwd ?? "").split(whereSeparator: \.isNewline).map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 4 }
        let uid: Int
        var primary: Int?
        if let value = number(userPart) {
            uid = value
            primary = entries.first { Self.number($0[2]) == value }.flatMap { Self.number($0[3]) }
        } else {
            guard let entry = entries.first(where: { $0[0] == userPart }), let value = Self.number(entry[2]), let gid = Self.number(entry[3]) else { return nil }
            uid = value
            primary = gid
        }
        guard let groupPart else { return WorkspaceUser(uid: uid, gid: primary) }
        if let gid = number(groupPart) { return WorkspaceUser(uid: uid, gid: gid) }
        let groups = (group ?? "").split(whereSeparator: \.isNewline).map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
        guard let entry = groups.first(where: { $0.count >= 3 && $0[0] == groupPart }), let gid = number(entry[2]) else { return nil }
        return WorkspaceUser(uid: uid, gid: gid)
    }

    /// The contents of the one file in a tar archive as the archive endpoint returns it for a file, at most `limit`
    /// bytes; nil when that entry is a link, a folder or anything but a regular file, or the archive is malformed.
    static func regularFile(inTar data: Data, limit: Int = 1 << 20) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { return nil }
            let sizeField = bytes[(offset + 124)..<(offset + 136)]
            // A base-256 size (high bit set) is far beyond any account file.
            guard sizeField.first.map({ $0 & 0x80 == 0 }) ?? false else { return nil }
            let text = String(decoding: sizeField.filter { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let size = text.isEmpty ? 0 : Int(text, radix: 8), size >= 0, size <= bytes.count else { return nil }
            let start = offset + 512
            guard start + size <= bytes.count else { return nil }
            switch bytes[offset + 156] {
            case UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K"):
                // Extended headers (long names, times) describe the next entry.
                offset = start + (size + 511) / 512 * 512
            case 0, UInt8(ascii: "0"):
                guard size <= limit else { return nil }
                return Data(bytes[start..<(start + size)])
            default:
                return nil
            }
        }
        return nil
    }
}
