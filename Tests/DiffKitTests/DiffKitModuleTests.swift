import BelloCore
import Testing
@testable import DiffKit

@Test func descriptorNamesItsModule() {
    #expect(DiffKitModule.descriptor.name == "DiffKit")
    #expect(!DiffKitModule.descriptor.responsibility.isEmpty)
}
