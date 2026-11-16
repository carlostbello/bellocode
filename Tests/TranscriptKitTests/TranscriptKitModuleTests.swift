import BelloCore
import Testing
@testable import TranscriptKit

@Test func descriptorNamesItsModule() {
    #expect(TranscriptKitModule.descriptor.name == "TranscriptKit")
    #expect(!TranscriptKitModule.descriptor.responsibility.isEmpty)
}
