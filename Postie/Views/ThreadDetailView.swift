import SwiftUI

struct ThreadDetailView: View {
    let thread: MailThread
    var canToggleStar = true
    let toggleStar: () -> Void
    @State private var scrollPosition: ScrollPosition
    @State private var viewportHeight: CGFloat = 0
    @State private var followsLatestLayout = true

    init(thread: MailThread, canToggleStar: Bool = true, toggleStar: @escaping () -> Void) {
        self.thread = thread
        self.canToggleStar = canToggleStar
        self.toggleStar = toggleStar
        _scrollPosition = State(initialValue: Self.openingScrollPosition(for: thread))
    }

    static func openingScrollPosition(for thread: MailThread) -> ScrollPosition {
        // Keep the subject visible for a single email. Conversations open at the newest header,
        // not at the bottom of its body, which may be many screens long.
        guard thread.messages.count > 1, let latest = thread.latestMessage else {
            return ScrollPosition(idType: String.self, edge: .top)
        }
        return ScrollPosition(id: latest.id, anchor: .top)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(thread.subject)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button(action: toggleStar) {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!canToggleStar)
                    .help(canToggleStar
                          ? (thread.isStarred ? String(localized: "Remove star") : String(localized: "Star conversation"))
                          : String(localized: "Stars cannot be changed yet."))
                    .accessibilityLabel(thread.isStarred ? String(localized: "Remove star") : String(localized: "Star conversation"))
                }

                ForEach(thread.messages) { message in
                    VStack(alignment: .leading, spacing: 16) {
                        MessageView(
                            message: message, expandedInitially: message.id == thread.latestMessage?.id,
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
            scrollPosition = Self.openingScrollPosition(for: thread)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MessageView: View {
    let message: MailMessage
    let interact: () -> Void
    let minimumExpandedHeight: CGFloat?
    @State private var isExpanded: Bool

    init(message: MailMessage, expandedInitially: Bool, minimumExpandedHeight: CGFloat?,
         interact: @escaping () -> Void) {
        self.message = message
        self.interact = interact
        self.minimumExpandedHeight = minimumExpandedHeight
        _isExpanded = State(initialValue: expandedInitially)
    }

    private var recipientsSummary: String {
        let to = String(localized: "To: \(message.recipient)")
        guard !message.cc.isEmpty else { return to }
        return to + " · " + String(localized: "Cc: \(message.cc)")
    }

    /// Only worth a line of its own when replies would go somewhere other than back to the sender.
    private var replyToSummary: String? {
        let replyTo = message.replyTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replyTo.isEmpty, GmailText.sender(replyTo).email.caseInsensitiveCompare(message.senderEmail) != .orderedSame
        else { return nil }
        return String(localized: "Reply-To: \(replyTo)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                interact()
                isExpanded.toggle()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    SenderAvatar(message: message, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(message.senderName)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if isExpanded {
                                Text(verbatim: "<\(message.senderEmail)>")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .lineLimit(1)
                        Text(isExpanded ? recipientsSummary : String(message.body.prefix(100)).replacingOccurrences(of: "\n", with: " "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if isExpanded, let replyToSummary {
                            Text(replyToSummary)
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
                if !message.attachments.isEmpty {
                    // Line up with the sender's name, past the avatar.
                    AttachmentList(attachments: message.attachments)
                        .padding(.leading, 42)
                }
                if let html = message.htmlBody {
                    HTMLMessageBody(html: html, plainText: message.body)
                        .id(message.id)
                } else {
                    Text(message.body)
                        .font(.body)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
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

private func longConversationPreview(html: Bool = false) -> MailThread {
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
    return MailThread(id: "long-conversation", subject: "Long conversation · newest message", messages: messages, mailbox: .inbox)
}

#Preview("Latest message · Long conversation") {
    let thread = longConversationPreview()
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 620, height: 640)
}

#Preview("Latest message · HTML compact dark") {
    let thread = longConversationPreview(html: true)
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 420, height: 640)
        .preferredColorScheme(.dark)
}
#endif
