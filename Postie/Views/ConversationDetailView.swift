import SwiftUI

/// The detail column: the open conversation, or why there isn't one.
struct ConversationDetailView: View {
    let model: InboxModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hub: MailHub { model.hub }

    var body: some View {
        let key = model.selectedID
        ZStack {
            if let key, let conversation = hub.openConversation(for: key),
               !(hub.isLoadingConversation(key) && !conversation.messages.allSatisfy(\.bodyLoaded)) {
                VStack(spacing: 0) {
                    if let error = hub.conversationError(key) {
                        GmailErrorBanner(message: error, retry: model.retrySelection)
                        Divider()
                    }
                    if hub.mailbox == .outbox, !hub.isSearchActive {
                        OutboxBanner(model: model, key: key)
                        Divider()
                    }
                    GmailConversationView(
                        conversation: conversation, mailbox: hub.mailbox, hub: hub, key: key,
                        canToggleStar: hub.canModifyLabels(key),
                        toggleStar: { model.toggleStar(MergedConversation(key: key, conversation: conversation)) },
                        openDraft: hub.canEditDraft(key) ? { model.editDraft(key) } : nil
                    )
                    .id(key)
                    // Fade the container, not the HTML layout or its scroll position.
                    .transaction { $0.animation = nil }
                    .environment(\.attachmentLoader, AttachmentLoader(hub: hub, accountID: key.accountID))
                }
            } else if hub.isLoadingConversation(key) {
                MailActivityIndicator(title: String(localized: "Loading conversation…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = hub.conversationError(key) {
                ContentUnavailableView {
                    Label("Could Not Load Conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: model.retrySelection)
                }
            } else {
                ContentUnavailableView {
                    Label("No Conversation Selected", systemImage: "envelope.open")
                } description: {
                    Text("Select a conversation to read it.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hub.isLoadingConversation(key))
        // Rapid keyboard navigation should switch directly, not stack outgoing conversations.
        .transaction(value: key) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

/// Projects a Gmail conversation into the shared thread view. Message IDs come from Gmail, so
/// expanded messages stay expanded when the conversation updates.
private struct GmailConversationView: View {
    let conversation: GmailConversation
    let mailbox: Mailbox
    let accountEmail: String?
    @State private var calendarModel: CalendarConversationModel
    let canToggleStar: Bool
    let toggleStar: () -> Void
    let openDraft: (() -> Void)?

    init(conversation: GmailConversation, mailbox: Mailbox, hub: MailHub, key: ConversationKey,
         canToggleStar: Bool, toggleStar: @escaping () -> Void, openDraft: (() -> Void)?) {
        self.conversation = conversation
        self.mailbox = mailbox
        self.accountEmail = hub.email(for: key.accountID)
        self.canToggleStar = canToggleStar
        self.toggleStar = toggleStar
        self.openDraft = openDraft
        _calendarModel = State(initialValue: CalendarConversationModel(hub: hub, key: key))
    }

    var body: some View {
        ThreadDetailView(
            thread: conversation.presentation(includingBodies: true, mailbox: mailbox),
            canToggleStar: canToggleStar, toggleStar: toggleStar, openDraft: openDraft, accountEmail: accountEmail
        )
        .environment(\.calendarModel, calendarModel)
        .task(id: calendarModel.loadRequest(for: conversation)) {
            await calendarModel.load(conversation)
        }
    }
}

#if DEBUG
#Preview("Calendar invitation in message") {
    let hub = MailHub(accounts: AccountStore(vault: MemoryAccountVault()), persistsMail: false, syncsInBackground: false)
    GmailConversationView(
        conversation: CalendarPreviewData.conversation, mailbox: .inbox, hub: hub,
        key: ConversationKey(accountID: "calendar-preview", threadID: "calendar-preview"),
        canToggleStar: false, toggleStar: {}, openDraft: nil
    )
    .frame(width: 680, height: 800)
}
#endif

/// Where a queued message stands, with what can be done about it.
private struct OutboxBanner: View {
    let model: InboxModel
    let key: ConversationKey

    private var hub: MailHub { model.hub }

    var body: some View {
        if let item = hub.outbox.item(key.threadID) {
            HStack(spacing: 10) {
                switch item.state {
                case .sending:
                    ProgressView().controlSize(.small)
                    Text("Sending…")
                case .queued:
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text(item.lastError.map { String(localized: "Waiting to retry: \($0)") } ?? String(localized: "Waiting to be sent"))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Not sent: \(item.lastError ?? "")")
                }
                Spacer()
                if hub.canActOnOutboxItem(key) {
                    Button("Send Now") { model.retryOutboxItem(key) }
                    Button("Edit") { model.editOutboxItem(key) }
                    Button("Delete", role: .destructive) { model.deleteOutboxItem(key) }
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
