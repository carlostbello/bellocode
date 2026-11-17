// Real-agent end-to-end run (written in the next step).
import Foundation

@MainActor
struct EndToEnd {
    let fixtures: String
    let binary: URL
    let snapshots: URL
    let downloads: URL

    func run() async -> Bool { false }
}
