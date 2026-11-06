import SwiftUI

/// A Google account's profile picture, or its initials while it loads or when there is none.
struct AccountAvatar: View {
    let identity: GoogleIdentity
    var size: CGFloat = 28

    var body: some View {
        AsyncImage(url: identity.picture) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Text(identity.initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        // AsyncImage keeps showing the old image when its URL becomes nil, as when switching to an account without a picture.
        .id(identity.picture)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// The selected account at the bottom of the sidebar. Clicking it switches to another account or adds one.
struct AccountSwitcher: View {
    let model: InboxModel
    @State private var isShowingAccounts = false

    private var accounts: AccountStore { model.hub.accounts }

    var body: some View {
        if let selected = accounts.selectedAccount {
            Button { isShowingAccounts = true } label: {
                HStack(spacing: 8) {
                    AccountAvatar(identity: selected.identity)
                    AccountName(identity: selected.identity)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Account: \(selected.email)"))
            .accessibilityHint(Text("Switches to another account"))
            .popover(isPresented: $isShowingAccounts, arrowEdge: .top) {
                accountList(selected: selected)
            }
        }
    }

    private func accountList(selected: AccountStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(accounts.accounts) { account in
                Button {
                    isShowingAccounts = false
                    model.selectAccount(account.id)
                } label: {
                    HStack(spacing: 8) {
                        AccountAvatar(identity: account.identity)
                        AccountName(identity: account.identity)
                        Spacer(minLength: 8)
                        if account.id == selected.id {
                            Image(systemName: "checkmark")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("Selected"))
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 6)
            Button("Add Account…") {
                isShowingAccounts = false
                accounts.addAccount()
            }
            .buttonStyle(.plain)
            .disabled(accounts.isBusy || accounts.configurationIssue != nil)
            .padding(.vertical, 2)
            SettingsLink { Text("Manage Accounts…") }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// The account's name and address, or just the address when Google gave no name.
private struct AccountName: View {
    let identity: GoogleIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let name = identity.name, !name.isEmpty {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Text(identity.email)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
