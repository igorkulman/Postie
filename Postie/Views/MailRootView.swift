import SwiftUI

struct MailRootView: View {
    let hub: MailHub
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.showsDockBadge) private var showsDockBadge = true
    // Launch with `-PostieDemoData` to start on sample mail (e.g. for screenshots).
    @State private var showingDemo = ProcessInfo.processInfo.arguments.contains("-PostieDemoData")
    @State private var demoUnreadCount: Int?
    // The welcome screen was on screen, so the next account is the first one: finish with the "all set" step.
    @State private var sawWelcome = false
    @State private var isOnboarding = false
    private let restoresSession: Bool
    private let updatesDockBadge: Bool

    init(hub: MailHub, restoresSession: Bool = true, updatesDockBadge: Bool = true) {
        self.hub = hub
        self.restoresSession = restoresSession
        self.updatesDockBadge = updatesDockBadge
    }

    private var accounts: AccountStore { hub.accounts }

    private var unreadCount: Int? {
        hub.sessions.isEmpty ? (showingDemo ? demoUnreadCount : nil) : hub.unreadInboxCount
    }

    var body: some View {
        ZStack {
            if hub.isPreparing {
                ProgressView("Opening saved mail…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isOnboarding, !accounts.accounts.isEmpty {
                AccountsReadyView(accounts: accounts) { isOnboarding = false }
            } else if !accounts.accounts.isEmpty {
                if hub.sessions.isEmpty {
                    ProgressView("Opening mailbox…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GmailInboxView(hub: hub)
                }
            } else if showingDemo {
                ContentView(unreadCountChanged: { demoUnreadCount = $0 })
            } else {
                WelcomeView(accounts: accounts, storageError: hub.storageError) { sawWelcome = true }
            }
        }
        .task {
            // Accounts first, so a returning person never sees the welcome screen flash by.
            if restoresSession, !showingDemo { accounts.restore() }
            await hub.prepare()
        }
        .task(id: AccountBinding(ids: accounts.accounts.map(\.id), ready: !hub.isPreparing)) {
            if !hub.isPreparing { await hub.reconcile() }
        }
        // Looks for new mail whenever the window comes back to the foreground.
        .task(id: scenePhase) {
            if scenePhase == .active { await hub.refresh() }
        }
        .onChange(of: unreadCount, initial: true) { _, _ in updateDockBadge() }
        .onChange(of: showsDockBadge) { _, _ in updateDockBadge() }
        .onChange(of: accounts.accounts.isEmpty) { _, isEmpty in
            guard !isEmpty else { return }
            showingDemo = false
            if sawWelcome { isOnboarding = true }
            sawWelcome = false
        }
    }

    private func updateDockBadge() {
        if updatesDockBadge { DockBadge.update(unreadCount: showsDockBadge ? unreadCount : nil) }
    }

    private struct AccountBinding: Hashable {
        let ids: [String]
        let ready: Bool
    }
}

/// Shown until the first account is connected.
private struct WelcomeView: View {
    let accounts: AccountStore
    let storageError: String?
    let appeared: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Welcome to Postie")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Read your mail in a native Mac app.\nLoaded mail is saved on this Mac for offline reading.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if accounts.isBusy {
                ProgressView("Connecting…")
            } else {
                Button { accounts.addAccount() } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(accounts.configurationIssue != nil)
            }

            if let issue = accounts.configurationIssue ?? accounts.error ?? storageError {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Postie")
        .onAppear(perform: appeared)
    }
}

/// Shown once after the first sign-in: confirms what is connected and lets the person add more before starting.
private struct AccountsReadyView: View {
    let accounts: AccountStore
    let start: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 6) {
                ForEach(accounts.accounts) { account in
                    Label(account.email, systemImage: "envelope")
                        .labelStyle(.titleAndIcon)
                }
            }
            .padding(14)
            .frame(maxWidth: 320)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connected accounts")
            Text("Mail from all your accounts appears together. You can add or remove accounts later in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if accounts.isBusy {
                ProgressView("Connecting…")
            } else {
                HStack(spacing: 12) {
                    Button("Add Another Account…") { accounts.addAccount() }
                    Button("Start Using Postie", action: start)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }

            if let error = accounts.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Postie")
    }
}

#Preview("Welcome") {
    let accounts = AccountStore(vault: MemoryAccountVault())
    MailRootView(
        hub: MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false),
        restoresSession: false, updatesDockBadge: false
    )
    .frame(width: 960, height: 640)
}

#Preview("All set") {
    let identity = GoogleIdentity(id: "a", email: "alex@example.com", name: nil)
    let accounts = AccountStore(vault: MemoryAccountVault([StoredAccount(
        identity: identity,
        credentials: GoogleCredentials(refreshToken: "", accessToken: "", expiresAt: .distantFuture, scopes: Set(GoogleOAuthClient.requiredScopes)),
        addedAt: Date()
    )]))
    accounts.restore()
    return AccountsReadyView(accounts: accounts) {}
        .frame(width: 960, height: 640)
}
