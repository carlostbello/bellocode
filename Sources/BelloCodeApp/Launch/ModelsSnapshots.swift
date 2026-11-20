import AgentUI
import AppKit
import BelloCore
import DesignSystem
import Engine
import OpenCodeKit
import SwiftUI

/// `--snapshot models` (docs/features/models.md): Settings ▸ Models in light and dark against the mock catalog (free
/// OpenCode models plus the paid Mock AI provider): `default` (nothing chosen: the reviewer resolves to a paid model),
/// `chosen` (every row set, one model no longer connected), `picker` (the reviewer row's picker with its choices) and
/// `window` (the pane inside the Settings window).
extension SnapshotRunner {
    func runModels() async -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("FAIL cannot create \(directory.path): \(error)")
            return false
        }
        let engine = runtime.engine
        await engine.start()
        _ = await waitUntil(timeout: .seconds(20)) { engine.root.connection == .live && !engine.root.projects.isEmpty }
        if let directory = engine.root.projects.first?.directory { await engine.refreshCatalog(directory: directory) }
        _ = await waitUntil(timeout: .seconds(10)) { engine.root.catalog.current?.models.isEmpty == false }
        let temporary = FileManager.default.temporaryDirectory.appending(path: "bellocode-models-snap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        await engine.useModelSettings(folder: GlobalConfigFolder(url: temporary))
        let settings = AppSettings(defaults: nil)
        var written: [String] = []
        func pane(_ model: ModelsSettingsModel) -> some View {
            ModelsSettingsView(model: model).padding(DS.Space.s24).background(SwiftUI.Color.ds.canvas).environment(\.openCodeSnapshot, true)
        }

        let fresh = ModelsSettingsModel(engine: engine, auth: nil, confirm: { _, _, _ in true })
        written += await renderHosted(pane(fresh), state: "default", title: "Models")

        await engine.models.setDefaultModel(ModelSelection(providerID: "mockai", modelID: "mock-large"))
        await engine.models.setSmallModel(ModelSelection(providerID: "mockai", modelID: "mock-small"))
        var reviewer = engine.auto.settings
        reviewer.choice = .specific(ModelSelection(providerID: "opencode", modelID: "big-pickle"))
        await engine.auto.updateSettings(reviewer)
        await engine.models.setGitText(.smallModel)
        await engine.models.setDelegated(.specific(ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5")))
        let chosen = ModelsSettingsModel(engine: engine, auth: nil, confirm: { _, _, _ in true })
        written += await renderHosted(pane(chosen), state: "chosen", title: "Models")

        // The reviewer row's picker: choices first, then each connected provider's models.
        reviewer.choice = .sameAsThread
        await engine.auto.updateSettings(reviewer)
        let picking = ModelsSettingsModel(engine: engine, auth: nil, confirm: { _, _, _ in true })
        picking.reviewer.prepareForOpen()
        written += await renderHosted(
            ModelPickerView(model: picking.reviewer) {}.background(SwiftUI.Color.ds.raised).padding(DS.Space.s12).background(SwiftUI.Color.ds.canvas),
            state: "picker", title: "Auto reviewer")

        let controller = SettingsWindowController(settings: settings, auth: nil, importSource: nil, engine: engine)
        controller.show(pane: "models")
        try? await Task.sleep(for: .milliseconds(400))
        if only.isEmpty || only.contains("window") { written += await renderWindow(controller.window, state: "window") }
        controller.close()

        for path in written { log("wrote \(path)") }
        log(written.isEmpty ? "FAIL nothing written" : "PASS \(written.count) images")
        return !written.isEmpty
    }
}
