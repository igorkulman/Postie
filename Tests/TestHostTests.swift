import Foundation
import Testing

@Suite("Unit-test host")
struct TestHostTests {
    @Test("The test plan disables live Google session restoration")
    func isolatedFromLiveAccounts() {
        #expect(ProcessInfo.processInfo.environment["IMAIL_UNIT_TESTS"] == "1")
    }
}
