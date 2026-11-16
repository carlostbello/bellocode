import BrowserKit
import Foundation

@MainActor
struct EndToEnd {
    let host: BrowserHost
    let fixtures: String
    let binary: URL
    let snapshots: URL
    let prompt: String?
    func run() async -> Bool { false }
}
