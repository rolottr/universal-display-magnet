import Testing

@testable import UniversalDisplayMagnetCore

@Suite struct VersionTests {
    @Test func comparesReleaseTags() {
        #expect(SemanticVersion("v1.0.1")! > SemanticVersion("1.0.0")!)
        #expect(SemanticVersion("v1.10.0")! > SemanticVersion("v1.9.9")!)
        #expect(SemanticVersion("1.0")! == SemanticVersion("v1.0.0")!)
        #expect(SemanticVersion("v2.0.0-beta")!.description == "2.0.0")
        #expect(SemanticVersion("latest") == nil)
    }
}
