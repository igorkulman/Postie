import Foundation
import SwiftUI

/// How the process was launched. Only debug builds can run as the unit-test host or the
/// selection regression harness; release builds are always `.normal`.
private enum LaunchMode {
    case normal
    #if DEBUG
    case unitTests
    case selectionRegression
    #endif

    static var current: LaunchMode {
        #if DEBUG
        if ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] == "1" { return .unitTests }
        if ProcessInfo.processInfo.arguments.contains("-PostieSelectionRegression") { return .selectionRegression }
        #endif
        return .normal
    }

    /// Hosted unit tests and the regression harness must not read the real Keychain, restore an account or make Gmail requests.
    var usesLocalAccount: Bool {
        #if DEBUG
        self != .normal
        #else
        false
        #endif
    }

    var isUnitTest: Bool {
        #if DEBUG
        self == .unitTests
        #else
        false
        #endif
    }
}

@main
struct PostieApp: App {
    @State private var hub: MailHub
    private let launchMode = LaunchMode.current

    init() {
        let launchMode = LaunchMode.current
        let accounts = launchMode.usesLocalAccount ? AccountStore(vault: MemoryAccountVault()) : AccountStore()
        _hub = State(initialValue: MailHub(
            accounts: accounts, persistsMail: !launchMode.usesLocalAccount, syncsInBackground: !launchMode.usesLocalAccount
        ))
    }

    var body: some Scene {
        Window("Postie", id: "main") {
            root
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands { MailCommands() }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(hub: hub)
        }
    }

    @ViewBuilder
    private var root: some View {
        #if DEBUG
        if launchMode == .selectionRegression {
            GmailSelectionRegressionView()
        } else {
            MailRootView(hub: hub, restoresSession: !launchMode.isUnitTest, updatesDockBadge: !launchMode.isUnitTest)
        }
        #else
        MailRootView(hub: hub)
        #endif
    }
}
