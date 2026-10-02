//
//  iMailApp.swift
//  iMail
//
//  Created by Igor Kulman on 02.10.2026.
//

import Foundation
import SwiftUI
import GoogleSignIn

@main
struct iMailApp: App {
    var body: some Scene {
        Window("iMail", id: "main") {
            // Hosted unit tests must not restore a real account or make Gmail requests.
            MailRootView(restoresSession: ProcessInfo.processInfo.environment["IMAIL_UNIT_TESTS"] != "1")
                .frame(minWidth: 960, minHeight: 640)
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)
    }
}
