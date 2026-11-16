import BelloCore
import Testing
@testable import BrowserKit

@Test func descriptorNamesItsModule() {
    #expect(BrowserKitModule.descriptor.name == "BrowserKit")
    #expect(!BrowserKitModule.descriptor.responsibility.isEmpty)
}
