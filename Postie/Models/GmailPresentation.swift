import Foundation

extension GmailConversation {
    /// The display model for a conversation. IDs come from Gmail, so the same mail keeps the same identity
    /// each time it is projected and views keep their state (such as which messages are expanded).
    @MainActor
    func presentation(includingBodies: Bool, mailbox: Mailbox = .inbox) -> MailThread {
        MailThread(
            id: id,
            subject: subject,
            messages: messages.map {
                MailMessage(id: $0.id, senderName: $0.senderName, senderEmail: $0.senderEmail,
                            recipient: $0.recipient, cc: $0.cc, replyTo: $0.replyTo, date: $0.date,
                            body: includingBodies
                                ? ($0.bodyLoaded ? $0.body : $0.snippet + "\n\n" + String(localized: "This message body has not been downloaded. Connect to Gmail to read it."))
                                : $0.snippet,
                            htmlBody: includingBodies ? $0.htmlBody : nil, attachments: $0.attachments)
            },
            mailbox: mailbox, isUnread: isUnread, isStarred: isStarred
        )
    }
}
