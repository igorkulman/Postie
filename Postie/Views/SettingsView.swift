import SwiftUI

enum SettingsKey {
    static let showsDockBadge = "showsDockBadge"
}

struct SettingsView: View {
    let hub: MailHub

    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") {
                AccountSettings(hub: hub)
            }
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
        }
        .scenePadding()
        .frame(width: 480, height: 340)
    }
}

private struct AccountSettings: View {
    let hub: MailHub
    @State private var selection: String?
    @State private var removing: AccountStore.Entry?

    private var accounts: AccountStore { hub.accounts }
    private var selectedAccount: AccountStore.Entry? { accounts.accounts.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if accounts.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add a Gmail account to read and send mail.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(accounts.accounts) { account in
                        AccountRow(account: account, isDefault: account.id == accounts.defaultAccount?.id)
                            .tag(account.id)
                            .contextMenu { menu(for: account) }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Accounts")
            }

            if let message = accounts.error {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let issue = accounts.configurationIssue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Add Account…") { accounts.addAccount() }
                    .disabled(accounts.isBusy || accounts.configurationIssue != nil)
                if accounts.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Connecting…") }
                Spacer()
                if let account = selectedAccount {
                    if account.needsReconnect {
                        Button("Reconnect") { accounts.reconnect(account.id) }
                            .disabled(accounts.isBusy)
                    }
                    Button("Make Default") { accounts.setDefault(account.id) }
                        .disabled(account.id == accounts.defaultAccount?.id)
                    Button("Remove…", role: .destructive) { removing = account }
                }
            }
        }
        .onChange(of: accounts.accounts) { _, current in
            if !current.contains(where: { $0.id == selection }) { selection = nil }
        }
        .confirmationDialog(
            removing.map { String(localized: "Remove \($0.email)?") } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Remove Account", role: .destructive) { Task { await hub.removeAccount(account.id) } }
        } message: { _ in
            Text("Mail saved on this Mac for offline reading will be removed. Nothing is deleted from Gmail.")
        }
    }

    @ViewBuilder
    private func menu(for account: AccountStore.Entry) -> some View {
        Button("Make Default") { accounts.setDefault(account.id) }
            .disabled(account.id == accounts.defaultAccount?.id)
        if account.needsReconnect {
            Button("Reconnect") { accounts.reconnect(account.id) }
        }
        Divider()
        Button("Remove…", role: .destructive) { removing = account }
    }
}

private struct AccountRow: View {
    let account: AccountStore.Entry
    let isDefault: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                if let name = account.identity.name, !name.isEmpty {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if account.needsReconnect {
                Label("Needs sign-in", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if isDefault {
                Text("Default")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.showsDockBadge) private var showsDockBadge = true
    @Environment(UpdaterModel.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Form {
            Toggle("Show unread count on the Dock icon", isOn: $showsDockBadge)
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
        }
        .formStyle(.grouped)
    }
}
