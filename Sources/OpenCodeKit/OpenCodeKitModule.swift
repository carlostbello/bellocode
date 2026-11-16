import BelloCore

/// OpenCodeKit: Owns the bundled opencode server: supervisor, HTTP transport, SSE event hub, DTOs, client MCP host.
public enum OpenCodeKitModule {
    public static let descriptor = ModuleDescriptor(
        name: "OpenCodeKit",
        responsibility: "Owns the bundled opencode server: supervisor, HTTP transport, SSE event hub, DTOs, client MCP host."
    )
}
