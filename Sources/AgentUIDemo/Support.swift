import AgentUI
import AppKit
import BelloCore
import Engine
import Foundation
import MockOpenCode
import OpenCodeKit
import SwiftUI
import DesignSystem

/// A failed demo assertion.
struct DemoFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw DemoFailure(description: message) }
    print("  ✓ \(message)")
}

@MainActor
func waitFor(_ message: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw DemoFailure(description: "timed out: \(message)") }
        try await Task.sleep(for: .milliseconds(10))
    }
    print("  ✓ \(message)")
}

/// URLs the demo "opened" (no browser is launched).
@MainActor
final class OpenedLog {
    var urls: [URL] = []
}

/// A mock server, an engine connected to it, and an AuthService, as the app would wire them.
@MainActor
final class DemoHarness {
    let server: MockOpenCodeServer
    let endpoint: MockOpenCodeEndpoint
    let engine: Engine
    let auth: AuthService
    let directory = "/tmp/mock-project"
    let openedLog = OpenedLog()
    var opened: [URL] { openedLog.urls }

    init() async throws {
        server = MockOpenCodeServer(scenario: .empty(), options: MockServerOptions(heartbeatInterval: nil))
        endpoint = try await server.start()
        var configuration = EngineConfiguration(server: .fixed(Self.connection(endpoint)), store: .inMemory)
        configuration.defaultDirectory = directory
        engine = try Engine(configuration: configuration)
        let client = OpenCodeClient(connection: Self.connection(endpoint))
        let log = openedLog
        auth = AuthService(
            client: { client }, directory: { "/tmp/mock-project" }, openURL: { url in log.urls.append(url) },
            pollInterval: .milliseconds(50))
        await engine.start()
        try await waitFor("engine live") { engine.root.connection == .live }
        await engine.refreshCatalog(directory: directory)
        try await waitFor("catalog loaded") { engine.root.catalog.catalog(for: directory) != nil }
    }

    static func connection(_ endpoint: MockOpenCodeEndpoint) -> ServerConnection {
        ServerConnection(baseURL: endpoint.url, credentials: ServerCredentials(password: endpoint.password ?? ""))
    }

    var client: OpenCodeClient { OpenCodeClient(connection: Self.connection(endpoint)) }

    /// A raw JSON request (routes OpenCodeKit does not wrap, such as creating a form).
    @discardableResult
    func request(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: endpoint.url.absoluteString + path)!)
        request.httpMethod = method
        if let header = endpoint.authorizationHeader { request.setValue(header, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body.data
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONValue.parse(data)) ?? .null
    }

    func stop() async {
        auth.shutdown()
        await engine.stop()
        await server.stop()
    }
}

/// Renders SwiftUI views offscreen to PNG files, in light and dark (no screen recording needed).
@MainActor
struct Snapshotter {
    let directory: URL
    var written: [String] = []

    init(directory: URL) throws {
        self.directory = directory
        // In-process renders cannot capture vibrancy: glass surfaces draw their solid fallback.
        DSGlassView.forcesSolidFallback = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Hosts `view` in an offscreen window of `width` (height fits the content unless given), lets SwiftUI settle,
    /// and writes `<name>-light.png` and `<name>-dark.png` at 2x.
    mutating func capture<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, @ViewBuilder _ view: () -> V) async throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let root = view()
                .frame(width: width, height: height, alignment: .topLeading)
                .background(SwiftUI.Color.ds.canvas)
                .environment(\.agentUIStyle, .standard)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height ?? 400), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(250))
            let size = height.map { NSSize(width: width, height: $0) } ?? NSSize(width: width, height: max(hosting.fittingSize.height, 20))
            window.setContentSize(size)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                throw DemoFailure(description: "could not render \(name)")
            }
            rep.size = hosting.bounds.size
            // Without font smoothing: `cacheDisplay` darkens stems (implementation-guide.md, snapshots).
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw DemoFailure(description: "no context for \(name)") }
            context.cgContext.setAllowsFontSmoothing(false)
            context.cgContext.setShouldSmoothFonts(false)
            hosting.displayIgnoringOpacity(hosting.bounds, in: context)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw DemoFailure(description: "no PNG for \(name)") }
            let url = directory.appending(path: "\(name)-\(suffix).png")
            try png.write(to: url)
            written.append(url.path)
            window.orderOut(nil)
            window.contentView = nil
        }
        print("  📷 \(name)")
    }
}
