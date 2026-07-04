import Testing

@testable import DirnexCore

@Suite("DirnexCore smoke")
struct DirnexCoreSmokeTests {
    @Test("core package exposes a version")
    func exposesVersion() {
        #expect(Dirnex.version == "0.0.1")
    }
}
