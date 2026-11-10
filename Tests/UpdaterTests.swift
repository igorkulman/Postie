import Foundation
import Testing

struct UpdaterTests {
    @Test("The built app enables automatic update checks before a user sets a preference")
    func automaticChecksDefault() {
        // Check the packaged configuration Sparkle reads, not a test fixture or live user defaults.
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == true)
    }
}
