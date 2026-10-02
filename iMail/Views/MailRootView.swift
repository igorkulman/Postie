import SwiftUI
import GoogleSignInSwift

struct MailRootView: View {
    @State private var account: GoogleAccount
    @State private var reader: GmailReaderStore
    @State private var showingDemo = false
    private let restoresSession: Bool

    init(restoresSession: Bool = true) {
        self.restoresSession = restoresSession
        let account = GoogleAccount()
        _account = State(initialValue: account)
        _reader = State(initialValue: GmailReaderStore(api: GmailAPI { try await account.accessToken() }))
    }

    var body: some View {
        Group {
            if account.email != nil {
                GmailInboxView(reader: reader)
            } else if showingDemo {
                ContentView()
            } else {
                connectionView
            }
        }
        .task { if restoresSession { await account.restore() } }
        .onChange(of: account.email) { _, email in
            showingDemo = false
            if email == nil { reader.reset() }
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

            if let issue = account.configurationIssue ?? account.error {
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
    MailRootView(restoresSession: false)
        .frame(width: 960, height: 640)
}
