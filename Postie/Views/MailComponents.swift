import SwiftUI

struct SenderAvatar: View {
    let message: MailMessage
    var size: CGFloat = 36

    var body: some View {
        Text(message.initials)
            .font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: Circle())
            .accessibilityHidden(true)
    }
}

struct MailThreadRow: View {
    let thread: MailThread
    var isPending = false
    var textSize = ConversationListTextSize.defaultSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // .increased while the row sits on the accent-colored selection background.
    @Environment(\.backgroundProminence) private var prominence

    private var pointSize: CGFloat { CGFloat(ConversationListTextSize.clamped(textSize)) }
    private var textScale: CGFloat { pointSize / CGFloat(ConversationListTextSize.defaultSize) }

    // At larger sizes, give the sender the full width rather than competing with the date.
    private var headerLayout: AnyLayout {
        pointSize >= 20
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    var body: some View {
        if let message = thread.latestMessage {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(thread.isUnread ? (prominence == .increased ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    headerLayout {
                        Text(thread.mailbox == .sent || thread.mailbox == .outbox ? message.recipient : message.senderName)
                            .font(.system(size: pointSize, weight: .semibold))
                            .lineLimit(1)
                        if pointSize < 20 { Spacer(minLength: 8) }
                        ZStack(alignment: .trailing) {
                            Text(message.date, format: Calendar.current.isDateInToday(message.date)
                                 ? .dateTime.hour().minute()
                                 : .dateTime.month(.abbreviated).day())
                                .font(.system(size: 11 * textScale))
                                .foregroundStyle(.secondary)
                                .opacity(isPending ? 0 : 1)
                            if isPending {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    HStack(spacing: 5) {
                        Text(thread.subject)
                            .font(.system(size: pointSize, weight: thread.isUnread ? .medium : .regular))
                            .lineLimit(1)
                        if thread.messages.count > 1 {
                            Text(thread.messages.count, format: .number)
                                .font(.system(size: 10 * textScale).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .fixedSize()
                                .help(String(localized: "\(thread.messages.count) messages"))
                        }
                        Spacer(minLength: 4)
                        if thread.isStarred {
                            // Stays orange on the selection highlight, like Mimestream.
                            Image(systemName: "star.fill")
                                .font(.system(size: pointSize))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(thread.preview)
                        .font(.system(size: pointSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    AttachmentChip(attachments: message.attachments, textScale: textScale)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
            // Keep the subject and preview when List measures a row with a compact height proposal.
            .fixedSize(horizontal: false, vertical: true)
            .background(NativeListRowSizing())
            .opacity(isPending ? 0.65 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isPending)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription(of: message))
            .accessibilityValue(isPending ? String(localized: "Updating…") : "")
        }
    }

    /// One spoken summary per row: state first, then who, what and when, then the preview.
    private func accessibilityDescription(of message: MailMessage) -> String {
        var parts: [String] = []
        if thread.isUnread { parts.append(String(localized: "Unread")) }
        if thread.isStarred { parts.append(String(localized: "Starred")) }
        parts.append(thread.mailbox == .sent ? String(localized: "To \(message.recipient)") : message.senderName)
        parts.append(thread.subject)
        if thread.messages.count > 1 {
            parts.append(String(localized: "\(thread.messages.count) messages", comment: "Number of messages in a conversation, spoken by VoiceOver"))
        }
        parts.append(message.date.formatted(date: .abbreviated, time: .shortened))
        parts.append(thread.preview)
        if let first = message.attachments.first {
            parts.append(String(localized: "Attachment \(first.filename)"))
            if message.attachments.count > 1 {
                parts.append(String(localized: "and \(message.attachments.count - 1) more"))
            }
        }
        return parts.joined(separator: ". ")
    }
}

/// The folder list of the Gmail reader.
struct MailboxSidebar: View {
    @Binding var selection: Mailbox?
    /// Unread or draft counts to show next to a folder.
    let badges: [Mailbox: Int]

    var body: some View {
        List(selection: $selection) {
            Section("Mailboxes") {
                ForEach(Mailbox.allCases) { mailbox in
                    Label(mailbox.title, systemImage: mailbox.symbol)
                        .badge(badges[mailbox] ?? 0)
                        .tag(mailbox)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
