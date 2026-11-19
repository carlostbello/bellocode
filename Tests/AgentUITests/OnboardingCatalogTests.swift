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
