import Foundation

/// Which stream a piece of multiplexed output belongs to.
public enum OutputStream: UInt8, Sendable, Equatable {
    case stdin = 0
    case stdout = 1
    case stderr = 2
    /// Docker's "systemerr": an error from the daemon itself, interleaved with output.
    case system = 3
}

public struct OutputChunk: Sendable, Equatable {
    public var stream: OutputStream
    public var bytes: Data
    public init(_ stream: OutputStream, _ bytes: Data) {
        self.stream = stream
        self.bytes = bytes
    }
}

public enum DemuxError: Error, Equatable, Sendable {
    case badStreamType(UInt8)
}

/// Decoder for Docker's multiplexed attach/exec/logs stream (non-TTY mode): an 8-byte header
/// `[stream, 0, 0, 0, size (big-endian UInt32)]` before each frame. Accepts arbitrary byte boundaries and emits payload
/// as it arrives (a 1 GB frame is never buffered), so memory use is bounded by the size of one input chunk plus seven
/// header bytes.
public struct StreamDemuxer: Sendable {
    private var header = Data()
    private var current: OutputStream = .stdout
    private var remaining = 0

    public init() {}

    /// True when no partial frame is pending: a stream that ends here ended cleanly.
    public var isAtFrameBoundary: Bool { header.isEmpty && remaining == 0 }

    public mutating func feed(_ input: Data) throws -> [OutputChunk] {
        var chunks: [OutputChunk] = []
        var index = input.startIndex
        while index < input.endIndex {
            if remaining > 0 {
                let take = min(remaining, input.endIndex - index)
                let piece = Data(input[index..<(index + take)])
                if let last = chunks.last, last.stream == current {
                    chunks[chunks.count - 1].bytes.append(piece)
                } else {
                    chunks.append(OutputChunk(current, piece))
                }
                remaining -= take
                index += take
                continue
            }
            let need = 8 - header.count
            let take = min(need, input.endIndex - index)
            header.append(input[index..<(index + take)])
            index += take
            if header.count == 8 {
                let bytes = [UInt8](header)
                header.removeAll(keepingCapacity: true)
                guard let stream = OutputStream(rawValue: bytes[0]) else { throw DemuxError.badStreamType(bytes[0]) }
                current = stream
                remaining = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
            }
        }
        return chunks
    }

    /// Encodes one frame (used by tests and the fake server).
    public static func frame(_ stream: OutputStream, _ payload: Data) -> Data {
        let size = UInt32(payload.count)
        var data = Data([stream.rawValue, 0, 0, 0, UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        data.append(payload)
        return data
    }
}
