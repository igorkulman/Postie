//
//  PostieApp.swift
//  Postie
//
//  Created by Igor Kulman on 02.10.2026.
//

import Foundation
import SwiftUI
import GoogleSignIn

@main
struct PostieApp: App {
    @State private var account = GoogleAccount()

    var body: some Scene {
        Window("Postie", id: "main") {
            // Hosted unit tests must not restore a real account or make Gmail requests.
            MailRootView(
                account: account,
                restoresSession: ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] != "1",
                updatesDockBadge: ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] != "1",
                persistsMail: ProcessInfo.processInfo.environment["POSTIE_UNIT_TESTS"] != "1"
            )
                .frame(minWidth: 960, minHeight: 640)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        .commands { MailCommands() }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(account: account)
        }
    }
}
