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
    // .increased while the row sits on the accent-colored selection background.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let message = thread.latestMessage {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(thread.isUnread ? (prominence == .increased ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.mailbox == .sent || thread.mailbox == .outbox ? message.recipient : message.senderName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(message.date, format: Calendar.current.isDateInToday(message.date)
                             ? .dateTime.hour().minute()
                             : .dateTime.month(.abbreviated).day())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Text(thread.subject)
                            .font(.callout.weight(thread.isUnread ? .medium : .regular))
                            .lineLimit(1)
                        if thread.messages.count > 1 {
                            Text(thread.messages.count, format: .number)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if thread.isStarred {
                            // Stays orange on the selection highlight, like Mimestream.
                            Image(systemName: "star.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(thread.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    AttachmentChip(attachments: message.attachments)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription(of: message))
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
    @Binding var selection: MailboxSelection?
    /// Whether to offer every account's inbox together, and its unread count.
    let showsAllInboxes: Bool
    let allInboxesBadge: Int
    /// Unread or draft counts to show next to a folder.
    let badges: [Mailbox: Int]
    let labels: LabelTree
    /// Whether a nested label shows what is inside it, by its path.
    let labelGroupExpansion: (String) -> Binding<Bool>
    @State private var showsMoreLabels = false

    var body: some View {
        List(selection: $selection) {
            Section("Mailboxes") {
                if showsAllInboxes {
                    Label(MailboxSelection.allInboxes.title, systemImage: MailboxSelection.allInboxes.symbol)
                        .badge(allInboxesBadge)
                        .tag(MailboxSelection.allInboxes)
                }
                ForEach(Mailbox.allCases) { mailbox in
                    Label(mailbox.title, systemImage: mailbox.symbol)
                        .badge(badges[mailbox] ?? 0)
                        .tag(MailboxSelection.folder(mailbox))
                }
            }
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(labels.roots) { LabelRow(node: $0, expansion: labelGroupExpansion) }
                    if !labels.more.isEmpty {
                        DisclosureGroup("More", isExpanded: $showsMoreLabels) {
                            ForEach(labels.more) { LabelRow(node: $0, expansion: labelGroupExpansion) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A label in the sidebar, with the labels nested in it.
private struct LabelRow: View {
    let node: LabelNode
    let expansion: (String) -> Binding<Bool>

    var body: some View {
        if node.children.isEmpty {
            title(unreadThreads: node.unreadThreads)
        } else {
            let isExpanded = expansion(node.path)
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.children) { LabelRow(node: $0, expansion: expansion) }
            } label: {
                let row = title(unreadThreads: isExpanded.wrappedValue ? node.unreadThreads : node.unreadThreadsIncludingChildren)
                if node.label == nil {
                    // A parent that is only part of its children's names has nothing to open, so a click expands it instead.
                    row.contentShape(.rect).onTapGesture { isExpanded.wrappedValue.toggle() }
                } else {
                    row
                }
            }
        }
    }

    @ViewBuilder
    private func title(unreadThreads: Int) -> some View {
        // The sidebar ignores a weight set on the whole Label.
        let row = Label {
            Text(node.title).fontWeight(unreadThreads > 0 ? .semibold : nil).lineLimit(1)
        } icon: {
            Image(systemName: "tag")
        }
        .badge(unreadThreads)
        if let label = node.label {
            row.tag(MailboxSelection.folder(.label(label.id)))
        } else {
            row
        }
    }
}
