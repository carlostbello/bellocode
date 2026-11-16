import Testing
@testable import BelloCore

@Test func descriptorDescriptionCombinesNameAndResponsibility() {
    let descriptor = ModuleDescriptor(name: "Example", responsibility: "Does one thing.")
    #expect(descriptor.description == "Example: Does one thing.")
    #expect(BelloCoreModule.descriptor.name == "BelloCore")
}
