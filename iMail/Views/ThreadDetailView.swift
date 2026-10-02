import SwiftUI

struct ThreadDetailView: View {
    let thread: MailThread
    var canToggleStar = true
    let toggleStar: () -> Void

    var body: some View {
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
                    MessageView(message: message, expandedInitially: message.id == thread.latestMessage?.id)
                    if message.id != thread.latestMessage?.id {
                        Divider()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MessageView: View {
    let message: MailMessage
    @State private var isExpanded: Bool

    init(message: MailMessage, expandedInitially: Bool) {
        self.message = message
        _isExpanded = State(initialValue: expandedInitially)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
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
    }
}

#Preview("Conversation") {
    let thread = SampleMail.threads()[0]
    ThreadDetailView(thread: thread, toggleStar: {})
        .frame(width: 680, height: 800)
}
