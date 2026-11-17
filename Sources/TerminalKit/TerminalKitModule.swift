import BelloCore

/// TerminalKit: per-thread terminals on opencode's persistent PTYs, rendered by SwiftTerm (docs/features/terminal.md).
public enum TerminalKitModule {
    public static let descriptor = ModuleDescriptor(
        name: "TerminalKit",
        responsibility: "Terminal drawer, panel tabs and emulator views on opencode's persistent PTYs."
    )
}
