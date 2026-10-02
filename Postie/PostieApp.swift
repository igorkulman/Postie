import Foundation
import SwiftUI

@main
struct PostieApp: App {
    @State private var hub: MailHub
    private let isUnitTest = ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] == "1"

    init() {
        // Hosted unit tests must not read the real Keychain, restore an account or make Gmail requests.
        let isUnitTest = ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] == "1"
        let accounts = isUnitTest ? AccountStore(vault: MemoryAccountVault()) : AccountStore()
        _hub = State(initialValue: MailHub(accounts: accounts, persistsMail: !isUnitTest, syncsInBackground: !isUnitTest))
    }

    var body: some Scene {
        Window("Postie", id: "main") {
            MailRootView(hub: hub, restoresSession: !isUnitTest, updatesDockBadge: !isUnitTest)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands { MailCommands() }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(hub: hub)
        }
    }
}
