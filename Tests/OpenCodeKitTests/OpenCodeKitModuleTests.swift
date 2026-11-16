import BelloCore
import Testing
@testable import OpenCodeKit

@Test func descriptorNamesItsModule() {
    #expect(OpenCodeKitModule.descriptor.name == "OpenCodeKit")
    #expect(!OpenCodeKitModule.descriptor.responsibility.isEmpty)
}
