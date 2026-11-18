// swift-tools-version: 6.4
//
// BelloCode module layout (docs/PLAN.md, section 4).
//
// Add new source files inside an existing target directory; SwiftPM picks them up without edits here.
// Edit this manifest only to add a module, a dependency edge, a resource, or a third-party package.

import Foundation
import PackageDescription

// MARK: - Shared settings

/// Swift 6 language mode already implies complete strict-concurrency checking.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

/// Command Line Tools (no Xcode) ship Swift Testing, but the default `swiftbuild` build system does not pass the
/// Testing macro plugin to every compile job, so `@Test` fails with "plugin for module 'TestingMacros' not found".
/// Pointing the compiler at the plugin directory fixes it. The flag is added only when that directory exists; if Xcode
/// becomes the active toolchain and this causes trouble, drop it. See docs/spikes/G4-packaging.md.
let commandLineToolsTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = swiftSettings + (
    FileManager.default.fileExists(atPath: commandLineToolsTestingPlugins)
        ? [.unsafeFlags(["-plugin-path", commandLineToolsTestingPlugins])]
        : []
)

// MARK: - Third-party packages

// Later work packages add their dependencies here, each pinned to an exact or up-to-next-minor version,
// and then reference them from the targets below.
//
//   .package(url: "https://github.com/groue/GRDB.swift", ...)                        // Engine: projection store
//   .package(url: "https://github.com/swiftlang/swift-markdown", ...)                // TranscriptKit: Markdown
//   .package(url: "https://github.com/tree-sitter/swift-tree-sitter", ...)  // TranscriptKit, DiffKit: highlighting
//   .package(url: "https://github.com/migueldeicaza/SwiftTerm", ...)                // TerminalKit
let packageDependencies: [Package.Dependency] = [
    // G5 spike: terminal emulator (MIT). Exact pin; 1.99.x is the pre-2.0 line. See docs/spikes/G5-terminal.md.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
    .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
    // M1-F: GFM Markdown (cmark-gfm) for the transcript. Apache 2.0. See docs/features/transcript.md.
    .package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.9.0"),
]

// MARK: - Targets

/// A library target plus its test target (`Tests/<Name>Tests`).
func library(_ name: String, dependencies: [Target.Dependency] = [], testDependencies: [Target.Dependency] = []) -> [Target] {
    [
        .target(name: name, dependencies: dependencies, swiftSettings: swiftSettings),
        .testTarget(
            name: "\(name)Tests",
            dependencies: [.target(name: name)] + testDependencies,
            swiftSettings: testSwiftSettings
        ),
    ]
}

let uiKitDependencies: [Target.Dependency] = ["BelloCore", "DesignSystem"]

let targets: [Target] =
    library("BelloCore")
    + library("OpenCodeKit", dependencies: ["BelloCore"], testDependencies: ["MockOpenCode"])
    + library(
        "Engine", dependencies: ["BelloCore", "OpenCodeKit", "ContainerKit", "SecretKit", .product(name: "GRDB", package: "GRDB.swift")],
        testDependencies: ["MockOpenCode", "SecretKit", "ContainerKit"]
    )
    + library("DesignSystem", dependencies: ["BelloCore"])
    + library(
        "TranscriptKit",
        dependencies: uiKitDependencies + ["Engine", .product(name: "Markdown", package: "swift-markdown")],
        testDependencies: ["Engine", "MockOpenCode", "OpenCodeKit"]
    )
    + library("ComposerKit", dependencies: uiKitDependencies + ["Engine"])
    // M2-C: diff engine and views, Changes panel, workspace and branch pickers (docs/features/diff-git.md). Reuses
    // TranscriptKit's public HighlightService.
    + library(
        "DiffKit", dependencies: uiKitDependencies + ["Engine", "TranscriptKit"],
        testDependencies: ["Engine", "OpenCodeKit", "MockOpenCode", "BelloCore"])
    // M2-A: terminals on opencode's persistent PTYs (docs/features/terminal.md). Engine owns the PTY records and streams.
    + library(
        "TerminalKit", dependencies: uiKitDependencies + ["Engine", .product(name: "SwiftTerm", package: "SwiftTerm")],
        testDependencies: ["Engine", "OpenCodeKit", "MockOpenCode", "BelloCore"])
    // M4-A: the built-in browser and the agent bridge (docs/features/browser.md). Engine owns the attachments.
    + library(
        "BrowserKit", dependencies: uiKitDependencies + ["OpenCodeKit", "Engine"],
        testDependencies: ["Engine", "OpenCodeKit", "MockOpenCode", "BelloCore"])
    + library("MockOpenCode", dependencies: ["BelloCore", "OpenCodeKit"])
    // M1-D: approvals, questions, permission modes, model picker, onboarding and accounts (docs/features/agent-ui.md).
    + library("AgentUI", dependencies: ["BelloCore", "OpenCodeKit", "Engine", "DesignSystem", "SecretKit"], testDependencies: ["MockOpenCode"])
    // M3-A: Agents panel, lineage rows, header strip text (docs/features/orchestration.md). Engine owns the task graph.
    + library("OrchestrationUI", dependencies: uiKitDependencies + ["Engine", "SecretKit"], testDependencies: ["Engine", "OpenCodeKit", "MockOpenCode", "SecretKit"])
    // M6-A: Docker Engine API client over Rancher Desktop's socket, workspace containers (docs/features/containers.md).
    + library("ContainerKit")
    // Secret manager (docs/features/secrets.md): binding rules, value scanner, the placeholder egress proxy and its CA.
    + library("SecretKit", dependencies: ["BelloCore", "ContainerKit"], testDependencies: ["ContainerKit"])
    + [
        // M6-A: the shell opencode is configured with; forwards every command into the workspace container. Bundled in
        // Contents/Helpers.
        .executableTarget(name: "bellocode-exec", dependencies: ["ContainerKit"], swiftSettings: swiftSettings),
        // M6-A harness: runtime status, production-path measurements, cleanup of test resources.
        .executableTarget(name: "ContainerDemo", dependencies: ["ContainerKit"], swiftSettings: swiftSettings),
        // M2-A terminal harness: drawer snapshots and throughput/latency scenarios (docs/features/terminal.md).
        .executableTarget(
            name: "TerminalDemo",
            dependencies: [
                "TerminalKit", "Engine", "OpenCodeKit", "MockOpenCode", "BelloCore", "DesignSystem",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: swiftSettings),
        .executableTarget(
            name: "BelloCodeApp",
            dependencies: [
                "BelloCore", "OpenCodeKit", "Engine", "DesignSystem", "TranscriptKit", "ComposerKit", "DiffKit",
                "TerminalKit", "BrowserKit", "MockOpenCode", "AgentUI", "OrchestrationUI", "ContainerKit", "SecretKit",
            ],
            // S1 (docs/reviews/deep-review-1.md): attaching to another server (`BELLOCODE_SERVER_URL`) and the mock and
            // snapshot modes exist only in development (debug) builds; a release build runs only the bundled,
            // supervised server with container execution.
            swiftSettings: swiftSettings + [.define("BELLOCODE_DEVELOPMENT", .when(configuration: .debug))]
        ),
        // Restyle step 0: every token and DesignSystem control in every state, light and dark, rendered to PNG
        // (`swift run DesignGallery`, docs/design/implementation-guide.md).
        .executableTarget(name: "DesignGallery", dependencies: ["DesignSystem", "BelloCore"], swiftSettings: swiftSettings),
        // M2-C diff harness: snapshots and scroll benchmarks (docs/features/diff-git.md).
        .executableTarget(
            name: "DiffDemo",
            dependencies: ["DiffKit", "Engine", "BelloCore", "DesignSystem", "TranscriptKit", "OpenCodeKit", "MockOpenCode"],
            swiftSettings: swiftSettings),
        // M1-C development harness: scripted composer scenarios and snapshots. See docs/features/composer.md.
        .executableTarget(name: "ComposerDemo", dependencies: ["ComposerKit", "DesignSystem"], swiftSettings: swiftSettings),
        // AgentUI demo and snapshot harness: `swift run AgentUIDemo --all` (docs/features/agent-ui.md).
        .executableTarget(
            name: "AgentUIDemo", dependencies: ["AgentUI", "Engine", "BelloCore", "OpenCodeKit", "MockOpenCode", "DesignSystem"],
            swiftSettings: swiftSettings),
        // M4-A browser harness: fixture site, operation self-test, snapshots and the real-agent end-to-end run
        // (docs/features/browser.md).
        .executableTarget(
            name: "BrowserDemo",
            dependencies: ["BrowserKit", "Engine", "OpenCodeKit", "MockOpenCode", "BelloCore", "DesignSystem"],
            swiftSettings: swiftSettings),
        // Spike G7: noVNC live view of the containerised Chromium in a WKWebView (docs/spikes/G7-chrome-browse-container.md).
        .executableTarget(name: "ChromeLiveViewDemo", swiftSettings: swiftSettings),
    ]
    + [
        // Window shell logic (sidebar tree, commands, restoration, undo, switch timing). `@testable import BelloCodeApp`.
        .testTarget(
            name: "BelloCodeAppTests",
            dependencies: [
                "BelloCodeApp", "Engine", "MockOpenCode", "ComposerKit", "AgentUI", "OpenCodeKit", "BelloCore", "OrchestrationUI",
            ],
            swiftSettings: testSwiftSettings
        ),
    ]

// M1-F transcript scenarios, measurements and snapshots against MockOpenCode (docs/features/transcript.md).
let transcriptDemo: Target = .executableTarget(
    name: "TranscriptDemo",
    dependencies: ["TranscriptKit", "Engine", "BelloCore", "DesignSystem", "MockOpenCode", "OpenCodeKit"],
    swiftSettings: swiftSettings
)

let package = Package(
    name: "BelloCode",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BelloCode", targets: ["BelloCodeApp"]),
    ],
    dependencies: packageDependencies,
    targets: targets + [transcriptDemo],
    swiftLanguageModes: [.v6]
)
