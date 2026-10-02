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
            return ScrollPosition(idType: UUID.self, edge: .top)
        }
        return ScrollPosition(id: latest.id, anchor: .top)
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the scroll viewport itself below native window chrome. Scroll-to-ID can
            // otherwise place the sender header underneath a translucent title bar.
            scrollingBody.padding(.top, geometry.safeAreaInsets.top)
        }
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(thread.subject)
                        .font(.system(size: 18, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: toggleStar) {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(!canToggleStar)
                    .help(canToggleStar ? (thread.isStarred ? "Remove star" : "Star conversation") : "Stars cannot be changed in read-only Gmail mode.")
                    .accessibilityLabel(thread.isStarred ? "Remove star" : "Star conversation")
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
                                Text("<\(message.senderEmail)>")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        Text(isExpanded ? "To: \(message.recipient)\(message.cc.isEmpty ? "" : " · Cc: " + message.cc)" : String(message.body.prefix(100)).replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(message.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") message from \(message.senderName)")
            .help(message.senderEmail)

            if isExpanded {
                if let html = message.htmlBody {
                    HTMLMessageBody(html: html, plainText: message.body)
                        .id(message.id)
                } else {
                    Text(message.body)
                        .font(.system(size: 13))
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

#Preview("Conversation") {
    let thread = SampleMail.threads()[0]
    ThreadDetailView(thread: thread, toggleStar: {})
        .id(thread.id)
        .frame(width: 680, height: 800)
}

private func longConversationPreview(html: Bool = false) -> MailThread {
    var messages = (1...20).map { index in
        MailMessage(senderName: "Earlier sender \(index)", senderEmail: "sender@example.com",
                    recipient: "alex@example.com", date: Date(timeIntervalSince1970: Double(index)),
                    body: "Earlier message \(index). Scroll up to read the conversation history.")
    }
    messages.append(MailMessage(
        senderName: "Latest sender", senderEmail: "latest@example.com", recipient: "alex@example.com",
        date: Date(timeIntervalSince1970: 21),
        body: "This is the newest message. The conversation should open at this header.\n\n"
            + String(repeating: "More of the latest message.\n\n", count: 60),
        htmlBody: html ? "<h2>This is the newest message</h2>"
            + String(repeating: "<p>More of the latest HTML message.</p>", count: 60) : nil
    ))
    return MailThread(subject: "Long conversation · newest message", messages: messages, mailbox: .inbox)
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
