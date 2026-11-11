import SwiftUI

/// Conversation context stays visible independently of the message scroll position.
struct ConversationHeaderView: View {
    let thread: MailThread
    let canToggleStar: Bool
    let isDraft: Bool
    let toggleStar: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.subject)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(thread.subject)
                    .accessibilityAddTraits(.isHeader)
                    .contextMenu {
                        Button("Copy Subject", systemImage: "doc.on.doc", action: copySubject)
                    }

                if thread.messages.count > 1 {
                    Text("\(thread.messages.count) messages")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isDraft {
                Text("Drafts")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }

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
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func copySubject() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(thread.subject, forType: .string)
    }
}
