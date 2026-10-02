import Foundation

nonisolated enum Mailbox: String, CaseIterable, Identifiable, Sendable {
    case inbox = "Inbox"
    case drafts = "Drafts"
    case outbox = "Outbox"
    case sent = "Sent"
    case archive = "Archive"
    case junk = "Junk"
    case trash = "Trash"

    var id: Self { self }

    /// The raw value is persisted and must stay stable; the title is what people read.
    var title: String {
        switch self {
        case .inbox: String(localized: "Inbox", comment: "Mailbox name")
        case .drafts: String(localized: "Drafts", comment: "Mailbox name")
        case .outbox: String(localized: "Outbox", comment: "Mailbox name")
        case .sent: String(localized: "Sent", comment: "Mailbox name")
        case .archive: String(localized: "Archive", comment: "Mailbox name")
        case .junk: String(localized: "Junk", comment: "Mailbox name")
        case .trash: String(localized: "Trash", comment: "Mailbox name")
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .outbox: "tray.and.arrow.up"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        }
    }
}

struct MailMessage: Identifiable, Equatable {
    let id: String
    var senderName: String
    var senderEmail: String
    var recipient: String
    var cc = ""
    var date: Date
    var body: String
    var htmlBody: String? = nil
    var attachments: [MailAttachment] = []

    var initials: String {
        senderName.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct MailThread: Identifiable, Equatable {
    let id: String
    var subject: String
    var messages: [MailMessage]
    var mailbox: Mailbox
    var isUnread = false
    var isStarred = false

    var latestMessage: MailMessage? { messages.last }
    var preview: String {
        latestMessage?.body.split(whereSeparator: \.isNewline).joined(separator: " ") ?? ""
    }
}

enum ComposeKind: String {
    case newMessage = "New message"
    case reply = "Reply"
    case replyAll = "Reply All"
    case forward = "Forward"

    var title: String {
        switch self {
        case .newMessage: String(localized: "New message", comment: "Composer title")
        case .reply: String(localized: "Reply", comment: "Composer title")
        case .replyAll: String(localized: "Reply All", comment: "Composer title")
        case .forward: String(localized: "Forward", comment: "Composer title")
        }
    }
}

struct ComposeDraft: Identifiable, Equatable {
    var id = UUID().uuidString
    var recipient = ""
    var cc = ""
    var subject = ""
    var body = ""
    var replyingTo: String?
    var gmailThreadID: String?
    /// The Gmail account the message is sent from; nil in the demo.
    var accountID: String?
    var kind: ComposeKind = .newMessage
    var updatedAt = Date()

    var hasContent: Bool {
        [recipient, cc, subject, body].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var canSend: Bool {
        EmailAddresses.isValidList(recipient)
            && (cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || EmailAddresses.isValidList(cc))
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ComposeDraft {
    /// A reply that goes to whoever wrote last, other than the account itself.
    static func reply(to thread: MailThread, accountEmail: String, allRecipients: Bool = false) -> ComposeDraft {
        let message = thread.messages.last(where: {
            $0.senderEmail.caseInsensitiveCompare(accountEmail) != .orderedSame
        }) ?? thread.latestMessage
        var seen: Set<String> = [accountEmail.lowercased()]
        func uniqueExternal(_ addresses: [String]) -> [String] {
            addresses.filter { address in
                !address.isEmpty && seen.insert(address.lowercased()).inserted
            }
        }
        let isOwnMessage = message?.senderEmail.caseInsensitiveCompare(accountEmail) == .orderedSame
        let primary = isOwnMessage ? EmailAddresses.split(message?.recipient ?? "") : [message?.senderEmail ?? ""]
        let to = uniqueExternal(primary)
        let cc = allRecipients ? uniqueExternal(
            EmailAddresses.split(message?.recipient ?? "") + EmailAddresses.split(message?.cc ?? "")
        ) : []
        let subject = thread.subject.lowercased().hasPrefix("re:") ? thread.subject : "Re: " + thread.subject
        return ComposeDraft(
            recipient: to.joined(separator: ", "), cc: cc.joined(separator: ", "),
            subject: subject, replyingTo: thread.id, kind: allRecipients ? .replyAll : .reply
        )
    }

    static func forward(_ thread: MailThread) -> ComposeDraft {
        let hasPrefix = thread.subject.lowercased().hasPrefix("fwd:") || thread.subject.lowercased().hasPrefix("fw:")
        let subject = hasPrefix ? thread.subject : "Fwd: " + thread.subject
        var body = ""
        if let message = thread.latestMessage {
            let ccHeader = message.cc.isEmpty ? "" : "\nCc: \(message.cc)"
            body = """


            ---------- Forwarded message ----------
            From: \(message.senderName) <\(message.senderEmail)>
            Date: \(message.date.formatted(date: .abbreviated, time: .shortened))
            Subject: \(thread.subject)
            To: \(message.recipient)\(ccHeader)

            \(message.body)
            """
        }
        return ComposeDraft(subject: subject, body: body, kind: .forward)
    }
}

// The demo supports comma-separated bare addresses, not full RFC display-name syntax.
enum EmailAddresses {
    static func split(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func isValidList(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return split(value).allSatisfy { address in
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2
                && !parts[0].isEmpty
                && parts[1].contains(".")
                && !parts[1].hasPrefix(".")
                && !parts[1].hasSuffix(".")
                && !address.contains(where: { $0.isWhitespace || $0.isNewline })
        }
    }
}
