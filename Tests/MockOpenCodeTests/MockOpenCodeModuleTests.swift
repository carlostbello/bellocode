import BelloCore
import Testing
@testable import MockOpenCode

@Test func descriptorNamesItsModule() {
    #expect(MockOpenCodeModule.descriptor.name == "MockOpenCode")
    #expect(!MockOpenCodeModule.descriptor.responsibility.isEmpty)
}
