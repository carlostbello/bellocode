import Foundation

/// Minimal ustar writer for build contexts and `PUT /archive` uploads (regular files and directories only).
public struct TarArchive: Sendable {
    public struct Entry: Sendable {
        public var path: String
        public var contents: Data
        public var mode: Int
        public var isDirectory: Bool
        public init(path: String, contents: Data = Data(), mode: Int = 0o644, isDirectory: Bool = false) {
            self.path = path
            self.contents = contents
            self.mode = mode
            self.isDirectory = isDirectory
        }
    }

    public var entries: [Entry] = []
    public init(_ entries: [Entry] = []) { self.entries = entries }

    public mutating func add(_ path: String, _ text: String, mode: Int = 0o644) {
        entries.append(Entry(path: path, contents: Data(text.utf8), mode: mode))
    }

    public func data() -> Data {
        var out = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ string: String, _ offset: Int, _ length: Int) {
                let bytes = Array(string.utf8.prefix(length))
                header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
            func octal(_ value: Int, _ offset: Int, _ length: Int) {
                put(String(value, radix: 8).leftPadded(to: length - 1) , offset, length - 1)
            }
            let name = entry.isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
            put(name, 0, 100)
            octal(entry.mode, 100, 8)
            octal(0, 108, 8)
            octal(0, 116, 8)
            octal(entry.isDirectory ? 0 : entry.contents.count, 124, 12)
            octal(0, 136, 12)
            header.replaceSubrange(148..<156, with: Array(repeating: 0x20, count: 8))
            header[156] = entry.isDirectory ? UInt8(ascii: "5") : UInt8(ascii: "0")
            put("ustar", 257, 6)
            put("00", 263, 2)
            let checksum = header.reduce(0) { $0 + Int($1) }
            put(String(checksum, radix: 8).leftPadded(to: 6), 148, 6)
            header[154] = 0
            header[155] = 0x20
            out.append(contentsOf: header)
            if !entry.isDirectory {
                out.append(entry.contents)
                let pad = (512 - entry.contents.count % 512) % 512
                out.append(Data(count: pad))
            }
        }
        out.append(Data(count: 1024))
        return out
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
