/// Names a BelloCode module and the single responsibility it owns.
///
/// Every module exposes one of these as `<Module>Module.descriptor` so the module map in docs/PLAN.md (section 4)
/// has a checked counterpart in code, and diagnostics can list what is linked.
public struct ModuleDescriptor: Sendable, Hashable, CustomStringConvertible {
    /// The SwiftPM target name, for example `"OpenCodeKit"`.
    public let name: String
    /// One sentence describing what belongs in the module and nothing else.
    public let responsibility: String

    public init(name: String, responsibility: String) {
        self.name = name
        self.responsibility = responsibility
    }

    public var description: String { "\(name): \(responsibility)" }
}

/// BelloCore: domain types and identifiers shared by every other module. It has no dependencies.
public enum BelloCoreModule {
    public static let descriptor = ModuleDescriptor(
        name: "BelloCore",
        responsibility: "Domain types and identifiers shared by every module; no dependencies."
    )
}
