import SwiftUI
import GoogleSignInSwift

struct MailRootView: View {
    @State private var account: GoogleAccount
    @State private var reader: GmailReaderStore
    @State private var showingDemo = false
    @State private var demoUnreadCount: Int?
    @State private var cache: GmailCache?
    @State private var readerAccount: CachedGmailAccount?
    @State private var preparingCache: Bool
    @State private var storageError: String?
    private let restoresSession: Bool
    private let updatesDockBadge: Bool
    private let persistsMail: Bool

    init(restoresSession: Bool = true, updatesDockBadge: Bool = true, persistsMail: Bool = true) {
        self.restoresSession = restoresSession
        self.updatesDockBadge = updatesDockBadge
        self.persistsMail = persistsMail
        _preparingCache = State(initialValue: persistsMail)
        let account = GoogleAccount()
        _account = State(initialValue: account)
        _reader = State(initialValue: GmailReaderStore(api: GmailAPI { try await account.accessToken() }))
    }

    private var unreadCount: Int? {
        if readerAccount != nil, account.accountID == nil || account.accountID == readerAccount?.id {
            return reader.unreadInboxCount
        }
        return showingDemo ? demoUnreadCount : nil
    }

    var body: some View {
        ZStack {
            if preparingCache {
                ProgressView("Opening saved mail…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let readerAccount, account.accountID == nil || account.accountID == readerAccount.id {
                GmailInboxView(
                    reader: reader, accountNotice: accountNotice,
                    reconnect: reconnectAction
                )
                    .id(readerAccount.id)
            } else if account.accountID != nil {
                ProgressView("Opening mailbox…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showingDemo {
                ContentView(unreadCountChanged: { demoUnreadCount = $0 })
            } else {
                connectionView
            }
        }
        .task {
            await prepareCache()
            if restoresSession { await account.restore() }
        }
        .task(id: AccountBinding(id: account.accountID, ready: !preparingCache)) {
            if !preparingCache, let id = account.accountID, let email = account.email {
                await bindReader(to: CachedGmailAccount(id: id, email: email))
            }
        }
        .onChange(of: unreadCount, initial: true) { _, count in
            if updatesDockBadge { DockBadge.update(unreadCount: count) }
        }
        .onChange(of: account.accountID) { previous, id in
            showingDemo = false
            if previous != nil && id == nil {
                reader.reset()
                readerAccount = nil
            }
        }
    }

    private struct AccountBinding: Hashable {
        let id: String?
        let ready: Bool
    }

    private var reconnectAction: (() -> Void)? {
        guard account.email == nil, !account.isBusy, account.configurationIssue == nil else { return nil }
        return { account.signIn() }
    }

    private var accountNotice: String? {
        if let storageError { return storageError }
        guard account.email == nil, let readerAccount else { return nil }
        return account.isBusy
            ? "Showing saved mail for \(readerAccount.email) while connecting to Google."
            : "Saved mail for \(readerAccount.email). Google is unavailable; downloaded messages can still be read."
    }

    private func prepareCache() async {
        guard persistsMail else { preparingCache = false; return }
        defer { preparingCache = false }
        do {
            let database = try await GmailCache.open()
            try Task.checkCancellation()
            cache = database
            account.useCache(database)
            if let savedAccount = try await database.latestAccount() {
                let savedSession = try await database.session(for: savedAccount)
                let savedReader = GmailReaderStore(api: GmailAPI { try await account.accessToken() }, cache: savedSession)
                await savedReader.restoreCachedMailbox()
                try Task.checkCancellation()
                reader = savedReader
                readerAccount = savedAccount
            }
        } catch is CancellationError {
            // Closing the window must not publish a partially prepared mailbox.
        } catch {
            storageError = "Unable to open saved mail. You can connect Gmail, but new mail may not be saved locally."
        }
    }

    private func bindReader(to identity: CachedGmailAccount) async {
        if readerAccount?.id == identity.id {
            // Cached mail can appear before OAuth restoration completes. Refresh again
            // once this account becomes connected, without recreating the reading pane.
            await reader.refresh()
            return
        }
        do {
            let savedSession = try await cache?.session(for: identity)
            let newReader = GmailReaderStore(api: GmailAPI { try await account.accessToken() }, cache: savedSession)
            await newReader.restoreCachedMailbox()
            try Task.checkCancellation()
            guard account.accountID == identity.id else { await savedSession?.invalidate(); return }
            reader.reset()
            reader = newReader
            readerAccount = identity
        } catch {
            guard !Task.isCancelled, account.accountID == identity.id else { return }
            storageError = "Unable to open the account cache. This session will use online mail only."
            reader.reset()
            reader = GmailReaderStore(api: GmailAPI { try await account.accessToken() })
            readerAccount = identity
        }
    }

    private var connectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Connect Gmail")
                .font(.system(size: 24, weight: .semibold))
            Text("Read your mail in a native Mac app.\nNo sending, mailbox changes, or email stored on disk.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if account.isBusy {
                ProgressView("Connecting…")
            } else {
                GoogleSignInButton(action: account.signIn)
                    .frame(width: 220)
                    .disabled(account.configurationIssue != nil)
            }

            if let issue = account.configurationIssue ?? account.error ?? storageError {
                Text(issue)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }

            Button("Explore the Demo") { showingDemo = true }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(account.isBusy)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("iMail")
    }
}

#Preview("Connect Gmail") {
    MailRootView(restoresSession: false, updatesDockBadge: false, persistsMail: false)
        .frame(width: 960, height: 640)
}
