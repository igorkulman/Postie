//
//  iMailApp.swift
//  iMail
//
//  Created by Igor Kulman on 02.10.2026.
//

import SwiftUI

@main
struct iMailApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.contentMinSize)
    }
}
