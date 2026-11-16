import BelloCore
import Testing
@testable import Engine

@Test func descriptorNamesItsModule() {
    #expect(EngineModule.descriptor.name == "Engine")
    #expect(!EngineModule.descriptor.responsibility.isEmpty)
}
