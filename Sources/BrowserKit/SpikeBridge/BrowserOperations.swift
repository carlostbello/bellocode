// SPIKE (gate G3). Per-operation implementations over one WebTab.

import AppKit
import WebKit

@MainActor
struct BrowserOperations {
    let host: BrowserHost
    let tab: WebTab

    func run(_ command: BrowserCommand) async throws -> BrowserResult {
        throw BrowserFailure("unsupported", "browser.\(command.type) is not supported by this BelloCode build.")
    }
}
