#if os(macOS)
import Testing
@testable import VantageClientLogic

struct MacDeviceNameTests {
    /// The Mac client used to call itself "iPad" and asked `Host.current()` for its name, which
    /// can wait on DNS.
    @Test @MainActor func theMacClientNamesItselfAsAMac() {
        let name = ClientSession.localDeviceName
        #expect(!name.isEmpty && name != "iPad")
        let model = ClientSession.hardwareModel()
        #expect(model != "iPad" && model != "arm64" && model != "x86_64")
        #expect(model.contains(","), "a model identifier like Mac15,6: \(model)")
    }
}
#endif
