import Engine
import Foundation
import Testing
@testable import BelloCodeApp

/// The fixes an environment banner offers open the pane that holds the fix (NF08).
@Suite("Environment fixes")
@MainActor
struct EnvironmentFixesTests {
    /// NF08: "Sign in to the registry" opens Settings ▸ Containers (the only pane with the registry sign-in form) from a
    /// thread or terminal banner and from Settings ▸ Project Environment, which both pass the project's folder.
    @Test func signInOpensTheContainersPaneWhereverItIsOffered() throws {
        let engine = try Engine(configuration: EngineConfiguration(server: .dynamic { nil }, store: .inMemory))
        for directory in ["/tmp/proj", nil] as [String?] {
            var opened: [String] = []
            EnvironmentFixes.perform(.signIn, directory: directory, engine: engine, openSettings: { opened.append($0) })
            #expect(opened == ["containers"], "directory \(directory ?? "none")")
            #expect(ContainersSettingsModel.focusRegistryPending, "the registry host field is focused once the pane shows")
            ContainersSettingsModel.focusRegistryPending = false
        }
        // "Open Settings" keeps opening the project's own Environment pane.
        var opened: [String] = []
        EnvironmentFixes.perform(.openSettings, directory: "/tmp/proj", engine: engine, openSettings: { opened.append($0) })
        #expect(opened == ["environment"])
        #expect(EnvironmentFixes.pane(for: .signIn, directory: "/tmp/proj") == "containers")
    }
}
