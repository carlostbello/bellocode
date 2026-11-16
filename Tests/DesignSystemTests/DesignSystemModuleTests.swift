import BelloCore
import Testing
@testable import DesignSystem

@Test func descriptorNamesItsModule() {
    #expect(DesignSystemModule.descriptor.name == "DesignSystem")
    #expect(!DesignSystemModule.descriptor.responsibility.isEmpty)
}
