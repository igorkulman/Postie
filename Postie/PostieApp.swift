import Foundation
import SwiftUI

@main
struct PostieApp: App {
    @State private var hub: MailHub
    private let isUnitTest = ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] == "1"
    private let isSelectionRegression = ProcessInfo.processInfo.arguments.contains("-PostieSelectionRegression")

    init() {
        // Hosted unit tests must not read the real Keychain, restore an account or make Gmail requests.
        let isUnitTest = ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] == "1"
        let usesLocalAccount = isUnitTest || ProcessInfo.processInfo.arguments.contains("-PostieSelectionRegression")
        let accounts = usesLocalAccount ? AccountStore(vault: MemoryAccountVault()) : AccountStore()
        _hub = State(initialValue: MailHub(accounts: accounts, persistsMail: !usesLocalAccount, syncsInBackground: !usesLocalAccount))
    }

    var body: some Scene {
        Window("Postie", id: "main") {
            Group {
                if isSelectionRegression, !isUnitTest {
                    GmailSelectionRegressionView()
                } else {
                    MailRootView(hub: hub, restoresSession: !isUnitTest, updatesDockBadge: !isUnitTest)
                }
            }
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
