import SwiftUI

/// The detail column: the open conversation, or why there isn't one.
struct ConversationDetailView: View {
    let model: InboxModel

    private var hub: MailHub { model.hub }

    var body: some View {
        let key = model.selectedID
        if let key, let conversation = hub.openConversation(for: key) {
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
                    conversation: conversation, mailbox: hub.mailbox,
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

/// Projects a Gmail conversation into the shared thread view. Message IDs come from Gmail, so
/// expanded messages stay expanded when the conversation updates.
private struct GmailConversationView: View {
    let conversation: GmailConversation
    let mailbox: Mailbox
    let canToggleStar: Bool
    let toggleStar: () -> Void
    let openDraft: (() -> Void)?

    var body: some View {
        ThreadDetailView(
            thread: conversation.presentation(includingBodies: true, mailbox: mailbox),
            canToggleStar: canToggleStar, toggleStar: toggleStar, openDraft: openDraft
        )
    }
}

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
