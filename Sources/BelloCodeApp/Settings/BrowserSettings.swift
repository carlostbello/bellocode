import BelloCore
import ContainerKit
import DesignSystem
import Engine
import Foundation
import Observation
import Synchronization
import OpenCodeKit
import SwiftUI

/// "Your Chrome": read-only detection of the separate `browse` tool (anomalyco/browse, an MCP server driving the
/// person's real Chrome through an extension). BelloCode never changes its configuration, the person's opencode config,
/// or BelloCode's own isolated opencode config from here.
@MainActor
@Observable
final class BrowseStatusModel {
    enum State: Equatable {
        case unknown, checking
        case notInstalled
        case installed(path: String, version: String)
    }

    private(set) var state: State = .unknown
    /// `browse status` (or `browse doctor`) output, bounded; never logged.
    private(set) var report = ""
    private(set) var isRunning = false
    /// Whether BelloCode's own (isolated) opencode config registers a `browse` MCP server.
    private(set) var configuredForBelloCode = false
    let configFile: URL

    static let candidates = [
        "~/.local/bin/browse", "/opt/homebrew/bin/browse", "/usr/local/bin/browse", "~/.bun/bin/browse", "~/.npm-global/bin/browse",
    ].map { NSString(string: $0).expandingTildeInPath }

    init(configDirectory: URL) {
        configFile = configDirectory.appending(path: "opencode/opencode.json")
    }

    func refresh() async {
        state = .checking
        configuredForBelloCode = Self.mentionsBrowse(configFile)
        guard let path = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            state = .notInstalled
            report = ""
            return
        }
        let version = await Self.run(path, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        state = .installed(path: path, version: version.isEmpty ? "unknown version" : String(version.prefix(80)))
        await run("status")
    }

    /// Runs `browse status` or `browse doctor` (read-only diagnostics) and shows its output.
    func run(_ subcommand: String) async {
        guard case .installed(let path, _) = state, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        report = await Self.run(path, [subcommand])
    }

    nonisolated static func mentionsBrowse(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file), data.count < 1 << 20,
              let object = JSONCheck.object(from: data) else { return false }  // JSONC, as opencode reads it (N28)
        let mcp = (object["mcp"] as? [String: Any]) ?? [:]
        let servers = (mcp["servers"] as? [String: Any]) ?? mcp
        return servers.keys.contains { $0.lowercased().contains("browse") }
    }

    /// Runs the tool with a 15 s limit and a minimal environment, drains both pipes, returns at most 8 KB of output.
    /// TERM then KILL at the limit; never blocks a thread on a pipe a leftover process holds (N18).
    nonisolated static func run(_ path: String, _ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = FileHandle.nullDevice  // ChildProcess sets it again (input or /dev/null)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(), "NO_COLOR": "1",
        ]
        do {
            let result = try await ChildProcess.run(process, ChildProcess.Options(timeout: .seconds(15), outputLimit: 8 * 1024, mergeOutput: true))
            return String(decoding: result.stdout, as: UTF8.self)
        } catch is ChildProcess.LaunchFailed {
            return "Could not run \(path)."
        } catch {
            return ""
        }
    }
}

/// Settings ▸ Browser: link handling, dev-server offers, and the "Your Chrome" status.
struct BrowserSettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var browse: BrowseStatusModel
    /// The shared Chromium (docs/features/shared-browser.md); nil without an engine.
    var sharedBrowser: SharedBrowserService? = nil

    var body: some View {
        SettingsPaneBody {
            if let sharedBrowser { SharedChromeSettingsGroup(service: sharedBrowser) }
            SettingsGroup("Links", footer: "Hold ⇧ while clicking a link to use the other browser.") {
                SettingsToggleRow("Open terminal links in the built-in browser", divided: false, isOn: $settings.terminalLinksOpenInBuiltInBrowser)
                SettingsToggleRow("Offer to open dev servers seen in terminal or agent output", isOn: $settings.offersDevServers)
            }
            SettingsGroup(
                "Built-in browser and your Chrome",
                footer: "BelloCode only reads this status. It does not change browse's setup, your opencode configuration or BelloCode's own."
            ) {
                SettingsRow(
                    "browse",
                    detail: "The built-in browser is for previews and for the agent: each project has its own website data, each thread its own tabs, and the agent only uses tabs it opened or you shared. For tasks that need your real logins, passkeys and extensions, the separate browse tool drives your own Chrome.",
                    divided: false
                ) { EmptyView() }
                SettingsRow("Status") { statusText.font(.ds(.label)).lineLimit(1).truncationMode(.middle) }
                SettingsRow("In BelloCode's opencode") {
                    Text(browse.configuredForBelloCode ? "Configured" : "Not configured")
                        .font(.ds(.label)).foregroundStyle(Color.ds.text2)
                        .help(browse.configFile.path)
                }
                SettingsRow("Check") {
                    HStack(spacing: DS.Space.s8) {
                        if browse.isRunning { DSStatusGlyphRepresentable(status: .running).frame(width: 14, height: 14) }
                        Button("Check Again") { Task { await browse.refresh() } }.buttonStyle(DSButtonStyle(.outline, size: .small))
                        Button("Run Doctor") { Task { await browse.run("doctor") } }
                            .buttonStyle(DSButtonStyle(.outline, size: .small))
                            .disabled(!isInstalled || browse.isRunning)
                    }
                }
                if !browse.report.isEmpty {
                    ScrollView {
                        Text(browse.report).font(.ds(.codeSmall)).foregroundStyle(Color.ds.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.s8)
                    }
                    .frame(height: 140)
                    .background(Color.ds.codeFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    .padding(DS.Space.s8)
                    .accessibilityLabel("browse output")
                }
            }
        }
        .task { if browse.state == .unknown { await browse.refresh() } }
    }

    private var isInstalled: Bool {
        if case .installed = browse.state { true } else { false }
    }

    @ViewBuilder private var statusText: some View {
        switch browse.state {
        case .unknown, .checking: Text("Checking…").foregroundStyle(Color.ds.text2)
        case .notInstalled: Text("Not installed (github.com/anomalyco/browse)").foregroundStyle(Color.ds.text2)
        case .installed(let path, let version): Text("\(version) at \((path as NSString).abbreviatingWithTildeInPath)").foregroundStyle(Color.ds.text2)
        }
    }
}
