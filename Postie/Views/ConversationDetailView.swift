import SwiftUI

/// The detail column: the open conversation, or why there isn't one.
struct ConversationDetailView: View {
    let model: InboxModel

    private var hub: MailHub { model.hub }

    var body: some View {
        let key = model.selectedID
        if model.selectedCount > 1 {
            SelectionStackView(
                threads: model.selectedKeys.prefix(SelectionStackView.tilts.count).compactMap {
                    hub.conversation(for: $0)?.presentation(includingBodies: false, mailbox: hub.mailbox)
                },
                count: model.selectedCount
            )
        } else if let key, let conversation = hub.openConversation(for: key),
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
                .environment(\.attachmentLoader, AttachmentLoader(hub: hub, accountID: key.accountID))
            }
        } else if hub.isLoadingConversation(key) {
            ProgressView("Loading conversation…")
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
}

/// Stands in for the open conversation while several are selected, which stay closed and unread.
private struct SelectionStackView: View {
    /// One tilt per card, front to back.
    static let tilts: [Double] = [0, -1.6, 1.4, -0.8]

    let threads: [MailThread]
    let count: Int

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                ForEach(Array(threads.enumerated().reversed()), id: \.element.id) { index, thread in
                    SelectionCard(thread: index == 0 ? thread : nil)
                        .rotationEffect(.degrees(Self.tilts[index]))
                }
            }
            .frame(maxWidth: 460)
            .accessibilityHidden(true)
            Text("\(count) Conversations Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A sheet of the stack. Only the front one has anything to show; the others just peek out behind it.
private struct SelectionCard: View {
    let thread: MailThread?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thread, let message = thread.latestMessage {
                HStack(alignment: .top, spacing: 10) {
                    SenderAvatar(message: message)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(thread.mailbox == .sent || thread.mailbox == .outbox ? message.recipient : message.senderName)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Text(thread.subject)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(thread.preview)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
    }
}

/// Projects a Gmail conversation into the shared thread view. Message IDs come from Gmail, so
/// expanded messages stay expanded when the conversation updates.
private struct GmailConversationView: View {
    let conversation: GmailConversation
    let mailbox: Mailbox
    @State private var calendarModel: CalendarConversationModel
    let canToggleStar: Bool
    let toggleStar: () -> Void
    let openDraft: (() -> Void)?

    init(conversation: GmailConversation, mailbox: Mailbox, hub: MailHub, key: ConversationKey,
         canToggleStar: Bool, toggleStar: @escaping () -> Void, openDraft: (() -> Void)?) {
        self.conversation = conversation
        self.mailbox = mailbox
        self.canToggleStar = canToggleStar
        self.toggleStar = toggleStar
        self.openDraft = openDraft
        _calendarModel = State(initialValue: CalendarConversationModel(hub: hub, key: key))
    }

    var body: some View {
        ThreadDetailView(
            thread: conversation.presentation(includingBodies: true, mailbox: mailbox),
            canToggleStar: canToggleStar, toggleStar: toggleStar, openDraft: openDraft
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
