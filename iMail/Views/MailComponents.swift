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

    var body: some View {
        if let message = thread.latestMessage {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(thread.isUnread ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.mailbox == .sent ? message.recipient : message.senderName)
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
                            Text("\(thread.messages.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if thread.isStarred {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(thread.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(thread.isUnread ? "Unread. " : "")\(message.senderName). \(thread.subject). \(thread.preview)")
        }
    }
}

struct DemoBadge: View {
    var body: some View {
        Label("Demo mode", systemImage: "sparkle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
            .help("Sample mail only. Gmail is not connected and no real email is sent.")
    }
}
