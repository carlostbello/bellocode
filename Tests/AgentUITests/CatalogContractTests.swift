import BelloCore
import Foundation
import OpenCodeKit
import Testing

@testable import AgentUI
@testable import Engine

/// The pinned contract's recorded provider catalogs (Contracts/opencode-<pin>/catalog-<provider>.json, captured by
/// `make opencode-upgrade` with a dummy key in a sandbox) through the real decoder, the engine's mapping and the model
/// picker: every model decodes and maps, and every model the upgrade diff lists as new is selectable by search.
@Suite("Recorded catalog contract")
@MainActor
struct CatalogContractTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func recorded() throws -> [String: [ModelInfo]] {
        let directory = try #require(OpenCodePin.contractsDirectory(root: root))
        var result: [String: [ModelInfo]] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("catalog-") && name.hasSuffix(".json") {
            let provider = String(name.dropFirst("catalog-".count).dropLast(".json".count))
            result[provider] = try JSONDecoder().decode([ModelInfo].self, from: Data(contentsOf: directory.appending(path: name)))
        }
        return result
    }

    @Test func everyRecordedModelDecodesAndMaps() throws {
        let catalogs = try Self.recorded()
        #expect(!catalogs.isEmpty, "the pinned contract records provider catalogs")
        for (provider, models) in catalogs {
            #expect(!models.isEmpty, "\(provider) lists models")
            for info in models {
                let entry = Mapping.model(info)
                #expect(entry.providerID == provider)
                #expect(!entry.name.isEmpty && entry.contextLimit > 0, "\(provider)/\(entry.modelID)")
                #expect(!entry.isFree || (entry.inputCost ?? 0) == 0)
                #expect(entry.modelID == info.id, "the entry ID, which model refs name, identifies the model")
            }
            let ids = models.map { Mapping.model($0).id }
            #expect(Set(ids).count == ids.count, "\(provider): every catalog entry is a distinct picker row")
        }
    }

    @Test func modelsNewInThisReleaseAreSelectableInThePicker() throws {
        let catalogs = try Self.recorded()
        let directory = try #require(OpenCodePin.contractsDirectory(root: Self.root))
        var added: [String: [String]] = [:]
        if let data = try? Data(contentsOf: directory.appending(path: "upgrade-diff.json")),
           let diff = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let catalog = diff["catalog"] as? [String: [String: [String]]] {
            for (provider, change) in catalog where catalogs[provider] != nil { added[provider] = change["added"] ?? [] }
        }
        let providers = catalogs.keys.sorted().map { ProviderEntry(id: $0, name: $0.capitalized, activation: "enabled", integrationID: $0) }
        let recordedCatalog = Catalog(
            directory: "/p", providers: providers, models: catalogs.values.flatMap { $0.map(Mapping.model) },
            fetched: Timestamp(milliseconds: 0))
        let picker = ModelPickerModel(
            catalog: { recordedCatalog }, current: { nil }, preferences: ModelPreferencesModel(store: nil), apply: { _ in nil },
            integrations: { [] }, onConnect: { _ in })
        for (provider, ids) in added {
            for id in ids {
                picker.query = id
                let row = picker.selectableRows.first { $0.model?.providerID == provider && $0.model?.modelID == id }
                #expect(row != nil, "\(provider)/\(id) is listed and selectable; top: \(picker.selectableRows.prefix(3).map(\.id))")
            }
        }
    }
}
