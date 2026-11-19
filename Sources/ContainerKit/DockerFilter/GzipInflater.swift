import Compression
import Foundation

/// Streaming gzip (RFC 1952) decoder for a build context passing through the filter (R14): Compose's classic builder
/// and `docker build --compress` send the context gzip-compressed. The header is parsed here (FEXTRA, FNAME, FCOMMENT
/// and FHCRC skipped, at any byte boundary); the DEFLATE body goes through the Compression framework's raw-DEFLATE
/// decoder (`COMPRESSION_ZLIB`). Output is handed out in bounded pieces and never kept, so a highly compressed context
/// costs time, not memory. The trailer's CRC is left to the daemon, which receives the original bytes.
final class GzipInflater {
    enum Failure: Error, Equatable {
        case notGzip
        case unsupportedMethod
        case corrupt
    }

    static let chunk = 64 * 1024

    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private var initialised = false
    private var header = Data()
    private var headerDone = false
    private(set) var finished = false

    deinit {
        if initialised { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    /// Decodes the next compressed bytes; `sink` receives each decompressed piece (at most `chunk` bytes) and returns
    /// false to stop early. Bytes after the end of the DEFLATE stream (the trailer, further members) are ignored.
    func feed(_ data: Data, sink: (Data) -> Bool) throws {
        guard !finished, !data.isEmpty else { return }
        var input = data
        if !headerDone {
            header.append(input)
            guard let length = try Self.headerLength(header) else {
                guard header.count <= 1 << 20 else { throw Failure.corrupt }
                return
            }
            headerDone = true
            input = header.subdata(in: header.startIndex.advanced(by: length)..<header.endIndex)
            header = Data()
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw Failure.corrupt
            }
            initialised = true
            if input.isEmpty { return }
        }
        var output = [UInt8](repeating: 0, count: Self.chunk)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            repeat {
                let status = output.withUnsafeMutableBufferPointer { buffer -> compression_status in
                    stream.pointee.dst_ptr = buffer.baseAddress!
                    stream.pointee.dst_size = buffer.count
                    return compression_stream_process(stream, 0)
                }
                let produced = Self.chunk - stream.pointee.dst_size
                if status == COMPRESSION_STATUS_ERROR { throw Failure.corrupt }
                if produced > 0, !sink(Data(output[0..<produced])) {
                    finished = true
                    return
                }
                if status == COMPRESSION_STATUS_END {
                    finished = true
                    return
                }
                // More output may be pending while the destination was filled; otherwise all input was consumed.
                if produced < Self.chunk, stream.pointee.src_size == 0 { return }
            } while true
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
