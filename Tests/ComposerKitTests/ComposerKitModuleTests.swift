import BelloCore
import Testing
@testable import ComposerKit

@Test func descriptorNamesItsModule() {
    #expect(ComposerKitModule.descriptor.name == "ComposerKit")
    #expect(!ComposerKitModule.descriptor.responsibility.isEmpty)
}
