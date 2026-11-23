import BelloCore
import Testing

@testable import AgentUI

/// R33: Skip promises free models only when the catalog actually lists some; loading and unavailable are explicit.
@Suite struct OnboardingCatalogTests {
    @Test func skipOnlyPromisesFreeModelsWhenTheCatalogHasThem() {
        let free = OnboardingCatalog.from(catalogLoaded: true, freeModels: ["Big Pickle"], timedOut: false)
        #expect(free == .free(["Big Pickle"]))
        #expect(free.skipDetail.contains("free models"))
        #expect(free.introduction.contains("start right away"))

        let none = OnboardingCatalog.from(catalogLoaded: true, freeModels: [], timedOut: false)
        #expect(none == .noFreeModels)
        let timedOut = OnboardingCatalog.from(catalogLoaded: false, freeModels: [], timedOut: true)
        #expect(timedOut == .unavailable)
        let loading = OnboardingCatalog.from(catalogLoaded: false, freeModels: [], timedOut: false)
        #expect(loading == .loading)
        for state in [none, timedOut, loading] {
            #expect(!state.skipDetail.contains("Use the free models"), "\(state)")
            #expect(!state.introduction.contains("start right away"), "\(state)")
            #expect(!state.hasFreeModels)
        }
        #expect(none.introduction.contains("Connect a provider"))
        #expect(timedOut.introduction.contains("could not be loaded"))
    }
}

/// v1.0.1 NV14: onboarding and Settings ▸ Accounts promise free models only when one can be chosen now.
@Suite struct FreeModelPromiseTests {
    let free = ModelEntry(providerID: "opencode", modelID: "free-1", name: "Big Pickle", isFree: true)
    func catalog(_ models: [ModelEntry], providers: [ProviderEntry] = []) -> Catalog {
        var catalog = Catalog(directory: "/p", models: models, fetched: Timestamp(milliseconds: 0))
        catalog.providers = providers
        return catalog
    }

    @Test func onboardingCountsOnlyUsableVisibleFreeModels() {
        #expect(OnboardingCatalog.from(catalog: catalog([free]), hidden: [], timedOut: false) == .free(["Big Pickle"]))
        var disabled = free
        disabled.enabled = false
        var deprecated = free
        deprecated.status = "deprecated"
        let providerOff = catalog([free], providers: [ProviderEntry(id: "opencode", name: "opencode", activation: "disabled")])
        for state in [
            OnboardingCatalog.from(catalog: catalog([disabled]), hidden: [], timedOut: false),
            OnboardingCatalog.from(catalog: catalog([deprecated]), hidden: [], timedOut: false),
            OnboardingCatalog.from(catalog: providerOff, hidden: [], timedOut: false),
            OnboardingCatalog.from(catalog: catalog([free]), hidden: [free.id], timedOut: false),
        ] {
            #expect(state == .noFreeModels, "\(state)")
        }
        #expect(OnboardingCatalog.from(catalog: nil, hidden: [], timedOut: true) == .unavailable)
    }

    @Test func accountsEmptyStatePromisesFreeModelsOnlyWhenOffered() {
        #expect(AccountsSettingsView.emptyAccountsMessage(freeModelsOffered: true).contains("free models"))
        #expect(!AccountsSettingsView.emptyAccountsMessage(freeModelsOffered: false).contains("free"))
    }
}
