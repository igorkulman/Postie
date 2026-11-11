import SwiftUI

struct MessageRecipientsView: View {
    let message: MailMessage
    let accountEmail: String?
    @State private var showsDetails: Bool

    init(message: MailMessage, accountEmail: String?, initiallyExpanded: Bool = false) {
        self.message = message
        self.accountEmail = accountEmail
        _showsDetails = State(initialValue: initiallyExpanded)
    }

    private var summary: String {
        RecipientSummary.text(to: message.recipient, cc: message.cc, accountEmail: accountEmail)
    }

    private var hasDifferentReplyTo: Bool {
        !message.replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GmailText.sender(message.replyTo).email.caseInsensitiveCompare(message.senderEmail) != .orderedSame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From: \(message.senderName) <\(message.senderEmail)>")
                    if !message.recipient.isEmpty { Text("To: \(message.recipient)") }
                    if !message.cc.isEmpty { Text("Cc: \(message.cc)") }
                    if !message.replyTo.isEmpty { Text("Reply-To: \(message.replyTo)") }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text(summary)
                    .lineLimit(1)
                    .help(summary)
            }
            .accessibilityHint("Shows full sender and recipient addresses")

            // Never hide the fact that Reply will go to someone other than the sender.
            if hasDifferentReplyTo, !showsDetails {
                Text("Reply-To: \(RecipientSummary.names(in: message.replyTo, accountEmail: accountEmail))")
                    .lineLimit(1)
                    .help(message.replyTo)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Expanded recipient details") {
    MessageRecipientsView(
        message: MailMessage(id: "recipients", senderName: "Acme News", senderEmail: "news@acme.example",
                             recipient: "\"Alex Example\" <alex@example.com>",
                             cc: "\"Doe, Jo\" <jo@example.com>, team@example.com",
                             replyTo: "Support <help@acme.example>", date: .now, body: ""),
        accountEmail: "alex@example.com", initiallyExpanded: true
    )
    .padding(20)
    .frame(width: 420)
}
#endif
