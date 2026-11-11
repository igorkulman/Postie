import SwiftUI

struct ThreadDetailView: View {
    let thread: MailThread
    var canToggleStar = true
    let toggleStar: () -> Void
    var openDraft: (() -> Void)?
    var accountEmail: String?
    @State private var isShowingHistory = false
    @State private var scrollPosition: ScrollPosition
    @State private var viewportHeight: CGFloat = 0
    @State private var followsLatestLayout = true

    init(thread: MailThread, canToggleStar: Bool = true, toggleStar: @escaping () -> Void, openDraft: (() -> Void)? = nil,
         accountEmail: String? = nil) {
        self.thread = thread
        self.canToggleStar = canToggleStar
        self.toggleStar = toggleStar
        self.openDraft = openDraft
        self.accountEmail = accountEmail
        _scrollPosition = State(initialValue: Self.openingScrollPosition(for: thread))
    }

    static func openingScrollPosition(for thread: MailThread) -> ScrollPosition {
        // Conversations open at the newest message header, not at the bottom of its body,
        // which may be many screens long. The conversation subject lives outside this scroll view.
        guard thread.messages.count > 1, let latest = thread.latestMessage else {
            return ScrollPosition(idType: String.self, edge: .top)
        }
        return ScrollPosition(id: latest.id, anchor: .top)
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderView(thread: thread, canToggleStar: canToggleStar,
                                   isDraft: openDraft != nil, toggleStar: toggleStar,
                                   isShowingHistory: isShowingHistory, navigateHistory: navigateHistory)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let openDraft {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            Text("This message is an unsent draft.")
                            Spacer(minLength: 8)
                            Button("Open Draft", action: openDraft)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 16) {
                            MessageView(
                                message: message, accountEmail: accountEmail, expandedInitially: message.id == thread.latestMessage?.id,
                                minimumExpandedHeight: thread.messages.count > 1 && message.id == thread.latestMessage?.id
                                    ? max(0, viewportHeight - 20) : nil
                            ) {
                                // Expanding history is intentional navigation too.
                                followsLatestLayout = false
                                scrollPosition.isPositionedByUser = true
                            }
                            if message.id != thread.latestMessage?.id {
                                Divider()
                            }
                        }
                        .id(message.id)
                    }
                }
                .scrollTargetLayout()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
                    // Initial targets exist only after layout; HTML can resize again after that.
                    guard followsLatestLayout, !scrollPosition.isPositionedByUser,
                          thread.messages.count > 1, let latest = thread.latestMessage else { return }
                    scrollPosition.scrollTo(id: latest.id, anchor: .top)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Stop following layout changes as soon as the user scrolls or expands history.
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                viewportHeight = height
            }
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onChange(of: thread.id) { _, _ in
                followsLatestLayout = true
                isShowingHistory = false
                scrollPosition = Self.openingScrollPosition(for: thread)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func navigateHistory() {
        guard let first = thread.messages.first, let latest = thread.latestMessage else { return }
        isShowingHistory.toggle()
        followsLatestLayout = !isShowingHistory
        scrollPosition = ScrollPosition(id: isShowingHistory ? first.id : latest.id, anchor: .top)
    }
}

private struct MessageView: View {
    let message: MailMessage
    let accountEmail: String?
    let interact: () -> Void
    let minimumExpandedHeight: CGFloat?
    @State private var isExpanded: Bool
    @AppStorage(SettingsKey.messageTextSize) private var messageTextSize = MessageTextSize.defaultSize

    init(message: MailMessage, accountEmail: String?, expandedInitially: Bool, minimumExpandedHeight: CGFloat?,
         interact: @escaping () -> Void) {
        self.message = message
        self.accountEmail = accountEmail
        self.interact = interact
        self.minimumExpandedHeight = minimumExpandedHeight
        _isExpanded = State(initialValue: expandedInitially)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                SenderAvatar(message: message, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        interact()
                        isExpanded.toggle()
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.senderName)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !isExpanded {
                                    Text(String(message.body.prefix(100)).replacingOccurrences(of: "\n", with: " "))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Message from \(message.senderName)")
                    .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                    .accessibilityHint(isExpanded ? String(localized: "Collapses the message") : String(localized: "Expands the message"))
                    .help(message.senderEmail)

                    if isExpanded {
                        MessageRecipientsView(message: message, accountEmail: accountEmail)
                    }
                }
            }

            if isExpanded {
                if !message.attachments.isEmpty {
                    // Line up with the sender's name, past the avatar.
                    AttachmentList(attachments: message.attachments)
                        .padding(.leading, 42)
                }
                if !message.calendarSources.isEmpty {
                    CalendarInvitationList(messageID: message.id)
                }
                if let html = message.htmlBody {
                    HTMLMessageBody(html: html, plainText: message.body, messageTextSize: messageTextSize)
                        .id(message.id)
                } else {
                    Text(message.body)
                        .font(.system(size: CGFloat(MessageTextSize.clamped(messageTextSize))))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Leave room to align the newest header even while its HTML body is still loading.
        .frame(minHeight: isExpanded ? minimumExpandedHeight : nil, alignment: .topLeading)
    }
}

#if DEBUG
#Preview("Conversation") {
    let thread = SampleMail.threads()[0]
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 680, height: 800)
}

#Preview("Reply-To") {
    let message = MailMessage(
        id: "reply-to", senderName: "Acme News", senderEmail: "news@acme.example", recipient: "me@example.com",
        cc: "team@example.com", replyTo: "Acme Support <help@acme.example>", date: Date(timeIntervalSince1970: 1_791_000_000),
        body: "Thanks for subscribing. Reply to this message to reach support."
    )
    ThreadDetailView(thread: MailThread(id: "reply-to", subject: "Welcome", messages: [message], mailbox: .inbox),
                     canToggleStar: false, toggleStar: {})
        .frame(width: 680, height: 260)
}

private func longConversationPreview(html: Bool = false, subject: String = "Long conversation · newest message") -> MailThread {
    var messages = (1...20).map { index in
        MailMessage(id: "earlier-\(index)", senderName: "Earlier sender \(index)", senderEmail: "sender@example.com",
                    recipient: "alex@example.com", date: Date(timeIntervalSince1970: Double(index)),
                    body: "Earlier message \(index). Scroll up to read the conversation history.")
    }
    messages.append(MailMessage(
        id: "latest", senderName: "Latest sender", senderEmail: "latest@example.com", recipient: "alex@example.com",
        date: Date(timeIntervalSince1970: 21),
        body: "This is the newest message. The conversation should open at this header.\n\n"
            + String(repeating: "More of the latest message.\n\n", count: 60),
        htmlBody: html ? "<h2>This is the newest message</h2>"
            + String(repeating: "<p>More of the latest HTML message.</p>", count: 60) : nil
    ))
    return MailThread(id: "long-conversation", subject: subject, messages: messages, mailbox: .inbox)
}

#Preview("Latest message · Long conversation") {
    let thread = longConversationPreview()
    ThreadDetailView(thread: thread, toggleStar: {}, accountEmail: "alex@example.com")
        .id(thread.id)
        .frame(width: 620, height: 640)
}

#Preview("Long subject · Compact") {
    let thread = longConversationPreview(
        subject: "Planning the next release: conversation headers, message navigation, and a few more details to review together before launch"
    )
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 420, height: 640)
}

#Preview("Latest message · HTML compact dark") {
    let thread = longConversationPreview(html: true)
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 420, height: 640)
        .preferredColorScheme(.dark)
}

#Preview("Wide plain-text reading") {
    let thread = MailThread(
        id: "wide-reading", subject: "A comfortable reading width", messages: [
            MailMessage(id: "wide-message", senderName: "Sophie Chen", senderEmail: "sophie@example.com",
                        recipient: "Alex Example <alex@example.com>", date: .now,
                        body: String(repeating: "Ordinary correspondence should be easy to follow without reading all the way across a wide window. ", count: 12))
        ], mailbox: .inbox
    )
    ThreadDetailView(thread: thread, toggleStar: {}, accountEmail: "alex@example.com")
        .frame(width: 1200, height: 600)
}
#endif
