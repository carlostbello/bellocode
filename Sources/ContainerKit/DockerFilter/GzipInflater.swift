import Foundation
import zlib

/// Streaming gzip (RFC 1952) decoder for a build context passing through the filter (R14): Compose's classic builder
/// and `docker build --compress` send the context gzip-compressed. zlib decodes each member (header with FEXTRA, FNAME,
/// FCOMMENT and FHCRC, DEFLATE body, CRC-checked trailer) and says exactly where it ended, so concatenated members are
/// decoded one after another, as Go's `compress/gzip` (the daemon's reader) does (N04); bytes after a member that are
/// not another gzip member fail. (The Compression framework reads past the end of a DEFLATE stream, so it cannot find
/// member boundaries.) Output is handed out in bounded pieces and never kept, so a highly compressed context costs
/// time, not memory.
final class GzipInflater {
    enum Failure: Error, Equatable {
        case notGzip
        case unsupportedMethod
        case corrupt
    }

    static let chunk = 64 * 1024

    private let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
    private var initialised = false
    /// Inside a member (its header started and its trailer not yet read).
    private var inMember = false
    private var members = 0
    /// The sink asked to stop: nothing more is decoded.
    private(set) var stopped = false

    init() {
        stream.initialize(to: z_stream())
    }

    deinit {
        if initialised { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
    }

    /// At least one whole member was decoded and the input ends between members (a clean end of the stream).
    var atMemberBoundary: Bool { members > 0 && !inMember }

    /// Decodes the next compressed bytes; `sink` receives each decompressed piece (at most `chunk` bytes) and returns
    /// false to stop early.
    func feed(_ data: Data, sink: (Data) -> Bool) throws {
        guard !stopped, !data.isEmpty else { return }
        if !initialised {
            // A first byte that is not gzip's magic is not a member at all.
            guard inflateInit2_(stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.corrupt }
            initialised = true
        }
        var output = [UInt8](repeating: 0, count: Self.chunk)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.next_in = UnsafeMutablePointer(mutating: base)
            stream.pointee.avail_in = uInt(raw.count)
            while !stopped {
                if !inMember {
                    guard stream.pointee.avail_in > 0 else { return }
                    // The next member starts: zlib checks its header (a byte that is not gzip's magic fails).
                    if members > 0, inflateReset(stream) != Z_OK { throw Failure.corrupt }
                    if stream.pointee.next_in.pointee != 0x1f { throw Failure.notGzip }
                    inMember = true
                }
                let status = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.pointee.next_out = buffer.baseAddress!
                    stream.pointee.avail_out = uInt(buffer.count)
                    return inflate(stream, Z_NO_FLUSH)
                }
                let produced = Self.chunk - Int(stream.pointee.avail_out)
                switch status {
                case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                    break
                default:
                    throw Failure.corrupt
                }
                if produced > 0, !sink(Data(output[0..<produced])) {
                    stopped = true
                    return
                }
                if status == Z_STREAM_END {
                    inMember = false
                    members += 1
                    continue
                }
                // All input used and nothing more to hand out: wait for more bytes.
                if stream.pointee.avail_in == 0, produced < Self.chunk { return }
                if status == Z_BUF_ERROR, produced == 0 { return }
            }
        }
    }

    /// The gzip header's length once all of it is in `data`, nil while more bytes are needed.
    static func headerLength(_ data: Data) throws -> Int? {
        let bytes = [UInt8](data.prefix(10))
        if bytes.count >= 2, bytes[0] != 0x1f || bytes[1] != 0x8b { throw Failure.notGzip }
        if bytes.count >= 3, bytes[2] != 8 { throw Failure.unsupportedMethod }
        guard bytes.count == 10 else { return nil }
        let flags = bytes[3]
        guard flags & 0xE0 == 0 else { throw Failure.corrupt }
        let all = [UInt8](data)
        var offset = 10
        if flags & 0x04 != 0 {
            guard all.count >= offset + 2 else { return nil }
            let extra = Int(all[offset]) | (Int(all[offset + 1]) << 8)
            offset += 2 + extra
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard offset <= all.count, let end = all[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        return all.count >= offset ? offset : nil
    }
}
