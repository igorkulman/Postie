#if DEBUG
import SwiftUI

private struct PreviewGmailAPI: GmailReading {
    let conversations: [Mailbox: [GmailConversation]]
    let failsBody: Bool

    func unreadInboxCount() async throws -> Int {
        (conversations[.inbox] ?? []).reduce(0) { total, conversation in
            total + conversation.messages.filter { $0.labelIDs.contains("UNREAD") }.count
        }
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        let mail = conversations[mailbox] ?? []
        return GmailPage(conversations: mail, nextPageToken: !mail.isEmpty && pageToken == nil ? "preview-next" : nil)
    }

    func conversation(id: String) async throws -> GmailConversation {
        if failsBody { throw GmailError.http(503) }
        guard let conversation = conversations.values.flatMap({ $0 }).first(where: { $0.id == id }) else { throw GmailError.http(404) }
        return conversation
    }
}

private func previewLabels(for thread: MailThread) -> Set<String> {
    var labels: Set<String> = []
    if thread.mailbox == .inbox { labels.insert("INBOX") }
    if thread.isUnread { labels.insert("UNREAD") }
    if thread.isStarred { labels.insert("STARRED") }
    return labels
}

private func previewConversation(_ thread: MailThread) -> GmailConversation {
    let labels = previewLabels(for: thread)
    let messages = thread.messages.map { message in
        GmailMessage(id: message.id, senderName: message.senderName, senderEmail: message.senderEmail,
                     recipient: message.recipient, cc: message.cc, date: message.date, snippet: thread.preview,
                     body: message.body, labelIDs: labels)
    }
    return GmailConversation(id: thread.id, subject: thread.subject, messages: messages)
}

@MainActor
private func makeGmailPreviewHub(mailbox: Mailbox = .inbox, failsBody: Bool = false) -> MailHub {
    let grouped = Dictionary(grouping: SampleMail.threads(), by: \.mailbox)
    let conversations = grouped.mapValues { $0.map(previewConversation) }
    let identity = GoogleIdentity(id: "preview", email: SampleAccount.email, name: SampleAccount.name)
    let credentials = GoogleCredentials(
        refreshToken: "", accessToken: "", expiresAt: .distantFuture, scopes: Set(GoogleOAuthClient.requiredScopes)
    )
    let accounts = AccountStore(vault: MemoryAccountVault([StoredAccount(identity: identity, credentials: credentials, addedAt: Date())]))
    accounts.restore()
    let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false) { _ in
        PreviewGmailAPI(conversations: conversations, failsBody: failsBody)
    }
    hub.changeMailbox(mailbox)
    return hub
}

private struct GmailPreview: View {
    @State private var hub: MailHub

    init(mailbox: Mailbox = .inbox, failsBody: Bool = false) {
        _hub = State(initialValue: makeGmailPreviewHub(mailbox: mailbox, failsBody: failsBody))
    }

    var body: some View {
        GmailInboxView(hub: hub)
            .task { await hub.reconcile() }
    }
}

#Preview("Gmail Reader") {
    GmailPreview()
        .frame(width: 1200, height: 820)
}

#Preview("Gmail Reader · Compact") {
    GmailPreview()
        .frame(width: 960, height: 640)
}

#Preview("Gmail Reader · Retry") {
    GmailPreview(failsBody: true)
        .frame(width: 960, height: 640)
}

#Preview("Gmail Sent · Dark") {
    GmailPreview(mailbox: .sent)
        .frame(width: 1200, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Gmail Outbox · Compact") {
    GmailPreview(mailbox: .outbox)
        .frame(width: 960, height: 640)
}
#endif
