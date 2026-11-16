import BelloCore
import Testing
@testable import TerminalKit

@Test func descriptorNamesItsModule() {
    #expect(TerminalKitModule.descriptor.name == "TerminalKit")
    #expect(!TerminalKitModule.descriptor.responsibility.isEmpty)
}
