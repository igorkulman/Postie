import SwiftUI

enum SettingsKey {
    static let showsDockBadge = "showsDockBadge"
}

struct SettingsView: View {
    let account: GoogleAccount

    var body: some View {
        TabView {
            Tab("Account", systemImage: "person.crop.circle") {
                AccountSettings(account: account)
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
        }
        .scenePadding()
        .frame(width: 460, height: 240)
    }
}

private struct AccountSettings: View {
    let account: GoogleAccount
    @State private var confirmsSignOut = false

    var body: some View {
        Form {
            if let email = account.email {
                LabeledContent("Signed in as", value: email)
                Button("Sign Out…", role: .destructive) { confirmsSignOut = true }
                    .disabled(account.isBusy)
            } else {
                LabeledContent("Account", value: "Not connected")
                Text("Connect Gmail from the main window.")
                    .foregroundStyle(.secondary)
            }
            if let error = account.error {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of Gmail?", isPresented: $confirmsSignOut) {
            Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Mail saved on this Mac for offline reading will be removed.")
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.showsDockBadge) private var showsDockBadge = true

    var body: some View {
        Form {
            Toggle("Show unread count on the Dock icon", isOn: $showsDockBadge)
        }
        .formStyle(.grouped)
    }
}
