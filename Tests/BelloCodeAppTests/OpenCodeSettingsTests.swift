import AppKit
import Foundation
import OpenCodeKit
import Testing
@testable import BelloCodeApp

/// Settings ▸ opencode: the command-line tool installer (idempotent, never touches files it did not create), the
/// stored repository-config policy and the menu commands (docs/features/opencode-config.md).
@Suite("opencode settings")
@MainActor
struct OpenCodeSettingsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "bellocode-cli-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeInstaller() throws -> (CommandLineToolInstaller, URL, URL) {
        let helper = root.appending(path: "BelloCode.app/Contents/Helpers/bellocode-opencode")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let bin = root.appending(path: "home/.local/bin", directoryHint: .isDirectory)
        return (CommandLineToolInstaller(helper: helper, candidates: [bin]), helper, bin)
    }

    @Test func installIsIdempotentAndUninstallRemovesOnlyOurLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (installer, helper, bin) = try makeInstaller()
        #expect(installer.status() == .notInstalled)
        #expect(installer.targetFolder() == bin)
        let link = try installer.install()
        #expect(link == bin.appending(path: "bellocode-opencode"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path)
        #expect(installer.status() == .installed(link))
        #expect(try installer.install() == link)  // again: no change, no error
        #expect(try installer.uninstall() == [link])
        #expect(!FileManager.default.fileExists(atPath: link.path))
        #expect(try installer.uninstall().isEmpty)
    }

    @Test func foreignFilesAndLinksAreNeverReplaced() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (installer, _, bin) = try makeInstaller()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appending(path: "bellocode-opencode")

        try Data("my own script".utf8).write(to: link)
        guard case .conflict = installer.status() else { Issue.record("a file should be a conflict"); return }
        #expect(throws: CommandLineToolInstaller.InstallError.self) { try installer.install() }
        #expect(try installer.uninstall().isEmpty)
        #expect(try String(contentsOf: link, encoding: .utf8) == "my own script")
        try FileManager.default.removeItem(at: link)

        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/local/bin/something-else")
        #expect(throws: CommandLineToolInstaller.InstallError.self) { try installer.install() }
        #expect(try installer.uninstall().isEmpty)
        try FileManager.default.removeItem(at: link)

        // A link to another BelloCode copy is ours: install repairs it.
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Applications/Old BelloCode.app/Contents/Helpers/bellocode-opencode")
        let repaired = try installer.install()
        #expect(installer.status() == .installed(repaired))
    }

    /// N33: a foreign file in an earlier folder shadows BelloCode's link in a later one.
    @Test func anEarlierForeignFileShadowsTheInstalledLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, helper, bin) = try makeInstaller()
        let later = root.appending(path: "usr/local/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: bin.appending(path: "bellocode-opencode"))
        try FileManager.default.createSymbolicLink(atPath: later.appending(path: "bellocode-opencode").path, withDestinationPath: helper.path)
        let installer = CommandLineToolInstaller(helper: helper, candidates: [bin, later])
        guard case .conflict(let path, let why) = installer.status() else { Issue.record("expected a conflict"); return }
        #expect(path == bin.appending(path: "bellocode-opencode"))
        #expect(why.contains("hides"))
    }

    /// N28: the browse check reads opencode.json as JSONC, as opencode does.
    @Test func browseDetectionReadsJSONC() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "opencode.json")
        try Data("{\r\n  // my servers\r\n  \"mcp\": { \"browse\": { \"type\": \"local\" }, },\r\n}".utf8).write(to: file)
        #expect(BrowseStatusModel.mentionsBrowse(file))
    }

    @Test func aBuildWithoutTheHelperCannotInstall() {
        let installer = CommandLineToolInstaller(helper: nil, candidates: [root])
        #expect(installer.status() == .unavailable)
        #expect(throws: CommandLineToolInstaller.InstallError.unavailable) { try installer.install() }
    }

    @Test func repositoryPolicyIsStoredAndReadAtLaunch() throws {
        let suite = "bellocode-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings.storedRepositoryConfig(defaults) == .bellocode)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.repositoryConfigPolicy == .bellocode)
        settings.repositoryConfigPolicy = .native
        #expect(AppSettings.storedRepositoryConfig(defaults) == .native)
        #expect(AppSettings(defaults: defaults).repositoryConfigPolicy == .native)
    }

    @Test func modelsSettingsHasAMenuItemAndShortcut() {
        let menu = MainMenu.make()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }
        let item = items(menu).first { $0.title == ShellCommand.showModelSettings.title }
        #expect(item != nil, "Window ▸ Models… missing")
        #expect(item?.keyEquivalent == "m")
        #expect(item?.keyEquivalentModifierMask == [.command, .control, .option])
    }

    @Test func everyOpenCodeActionHasAMenuItem() {
        let menu = MainMenu.make()
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(items) }
        let titles = Set(items(menu).map(\.title))
        for command in [ShellCommand.showOpenCodeSettings, .reloadOpenCode, .installCommandLineTool, .uninstallCommandLineTool] {
            #expect(titles.contains(command.title), "\(command.title) missing from the menu bar")
        }
    }
}
