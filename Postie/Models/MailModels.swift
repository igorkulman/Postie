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
    var replyTo = ""
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

enum ComposeKind: String, Codable, Hashable {
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

struct ComposeDraft: Identifiable, Equatable, Hashable, Codable {
    var id = UUID().uuidString
    var recipient = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    /// The quoted original that replies start with. It is part of `body`, but not something the person wrote.
    var quote = ""
    /// The formatted body the rich editor works on. Nil for plain-text drafts, like the demo's.
    /// `body` then holds its plain-text version.
    var html: String?
    /// What the person typed in the rich editor, without the quoted original. Nil until the editor reports it.
    var ownText: String?
    /// Files the person attached; read when the message is sent.
    var attachments: [URL] = []
    var replyingTo: String?
    var gmailThreadID: String?
    /// The Gmail account the message is sent from; nil in the demo.
    var accountID: String?
    var kind: ComposeKind = .newMessage
    var updatedAt = Date()

    /// What the person wrote, without the quoted original.
    private var written: String {
        ownText ?? (quote.isEmpty ? body : body.replacingOccurrences(of: quote, with: ""))
    }

    var hasContent: Bool {
        !attachments.isEmpty || [recipient, cc, bcc, subject, written].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var canSend: Bool {
        EmailAddresses.isValidList(recipient)
            && (cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || EmailAddresses.isValidList(cc))
            && (bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || EmailAddresses.isValidList(bcc))
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
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
        var quote = ""
        var html = HTMLText.emptyLine
        if let message {
            let author = message.senderName.isEmpty ? message.senderEmail : "\(message.senderName) <\(message.senderEmail)>"
            let when = message.date.formatted(date: .abbreviated, time: .shortened)
            let quoted = message.body.components(separatedBy: .newlines).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            quote = "\n\nOn \(when), \(author) wrote:\n\(quoted)"
            html += HTMLText.quote(attribution: "On \(when), \(author) wrote:", of: message)
        }
        return ComposeDraft(
            recipient: to.joined(separator: ", "), cc: cc.joined(separator: ", "),
            subject: subject, body: quote, quote: quote, html: html, replyingTo: thread.id, kind: allRecipients ? .replyAll : .reply
        )
    }

    static func forward(_ thread: MailThread) -> ComposeDraft {
        let hasPrefix = thread.subject.lowercased().hasPrefix("fwd:") || thread.subject.lowercased().hasPrefix("fw:")
        let subject = hasPrefix ? thread.subject : "Fwd: " + thread.subject
        var body = ""
        var html = HTMLText.emptyLine
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
            let when = message.date.formatted(date: .abbreviated, time: .shortened)
            var header = "---------- Forwarded message ---------<br>"
                + "From: <b>\(HTMLText.escape(message.senderName))</b> &lt;\(HTMLText.escape(message.senderEmail))&gt;<br>"
                + "Date: \(HTMLText.escape(when))<br>Subject: \(HTMLText.escape(thread.subject))<br>To: \(HTMLText.escape(message.recipient))<br>"
            if !message.cc.isEmpty { header += "Cc: \(HTMLText.escape(message.cc))<br>" }
            html += "<div class=\"gmail_quote\"><div class=\"gmail_attr\">\(header)</div><br>\(HTMLText.body(of: message))</div>"
        }
        return ComposeDraft(subject: subject, body: body, html: html, kind: .forward)
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

/// Builds and cleans the HTML that the rich composer starts from.
nonisolated enum HTMLText {
    /// A blank line for the person to start typing on, above any quoted text.
    static let emptyLine = "<div><br></div>"

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Gmail's own markup for a quoted original, so other clients fold it away like a Gmail reply.
    static func quote(attribution: String, of message: MailMessage) -> String {
        "<div class=\"gmail_quote\"><div class=\"gmail_attr\">\(escape(attribution))<br></div>"
            + "<blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">"
            + body(of: message) + "</blockquote></div>"
    }

    /// The original's formatted body when it has one, else its text with line breaks kept.
    static func body(of message: MailMessage) -> String {
        if let html = message.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stripActiveContent(html)
        }
        return escape(message.body).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Removes scripts, embedded content, styles and event handlers. Quoted mail is someone else's HTML,
    /// and it should neither run in the editor nor travel on in a reply.
    static func stripActiveContent(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "head", "title", "iframe", "object", "embed", "form", "svg", "math"] {
            result = result.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: "", options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "(?i)</?(?:html|body|meta|link|base|script|style|iframe|object|embed|form|input|button)\\b[^>]*>",
                                             with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)(href|src)\s*=\s*(["']?)\s*(?:javascript|vbscript):[^"'>\s]*\2"#,
                                             with: "$1=\"\"", options: .regularExpression)
        return result
    }
}
