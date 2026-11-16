// SPIKE G1-B (docs/spikes/G1-B-rows.md): canonical transcript model for the row-based candidate.
//
// Everything here is an immutable `Sendable` value. Row identity is `SpikeItem.id` (a stable server-style ID),
// never an array index.

import CoreGraphics
import Foundation

public enum SpikeRole: Sendable, Equatable {
    case user
    case assistant
}

public enum SpikeToolStatus: String, Sendable {
    case completed, error, running
}

public struct SpikeTool: Sendable {
    public var name: String
    public var title: String
    public var status: SpikeToolStatus
    public var output: String
    public var expandedByDefault: Bool
}

public struct SpikeImageRef: Sendable {
    public var imageID: Int
    public var pixelSize: CGSize
    public var colour: UInt32
    /// Delay after transcript open before the image "arrives" (simulated network/decode).
    public var delay: Double
}

public enum SpikePart: Sendable {
    case markdown(String)
    case tool(SpikeTool)
    case reasoning(String)
    case diff(String)
    case image(SpikeImageRef)
}

public struct SpikeItem: Sendable {
    public var id: Int
    public var role: SpikeRole
    public var parts: [SpikePart]
    /// Content revision; bumped whenever the server would send a new version of the message.
    public var revision: Int

    public var utf8Count: Int {
        parts.reduce(0) { total, part in
            switch part {
            case .markdown(let text), .reasoning(let text), .diff(let text): total + text.utf8.count
            case .tool(let tool): total + tool.title.utf8.count + tool.output.utf8.count
            case .image: total
            }
        }
    }

    public var imageIDs: [Int] {
        parts.compactMap { if case .image(let ref) = $0 { ref.imageID } else { nil } }
    }
}

/// Per-item presentation state that changes layout but not content: expanded/collapsed blocks.
/// Lives in the controller, outside reusable views.
public struct SpikeItemUIState: Sendable, Equatable {
    /// Block indices whose expansion differs from the block's default.
    public var toggled: Set<Int> = []
    /// Bumped on every change; part of the layout cache key.
    public var version: Int = 0
}
