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

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .outbox: "tray.and.arrow.up"
        case .archive: "archivebox"
        case .junk: "exclamationmark.shield"
        case .trash: "trash"
        }
    }
}

struct MailMessage: Identifiable, Equatable {
    var id = UUID()
    var senderName: String
    var senderEmail: String
    var recipient: String
    var cc = ""
    var date: Date
    var body: String
    var htmlBody: String? = nil

    var initials: String {
        senderName.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }
}

struct MailThread: Identifiable, Equatable {
    var id = UUID()
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
}

struct ComposeDraft: Identifiable, Equatable {
    var id = UUID()
    var recipient = ""
    var cc = ""
    var subject = ""
    var body = ""
    var replyingTo: UUID?
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
