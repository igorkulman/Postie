import Foundation

nonisolated struct OutgoingMessage: Sendable, Equatable {
    var from: String
    var to: String
    var cc: String = ""
    var subject: String
    var body: String
    /// Gmail thread to attach a reply to. Forwards and new messages start a new thread.
    var threadID: String?
}

nonisolated protocol GmailSending: Sendable {
    func send(_ message: OutgoingMessage) async throws
}

/// Builds a plain-text RFC 5322 message. Header values are stripped of line breaks so user input
/// can never inject extra headers.
nonisolated enum GmailMessageBuilder {
    static func rfc822(_ message: OutgoingMessage, inReplyTo: String? = nil, references: String? = nil,
                       date: Date = Date(), messageID: String = "<\(UUID().uuidString)@postie.local>") -> Data {
        var headers = [
            "From: " + clean(message.from),
            "To: " + clean(message.to)
        ]
        if !message.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { headers.append("Cc: " + clean(message.cc)) }
        headers.append("Subject: " + encodedSubject(message.subject))
        headers.append("Date: " + dateFormatter.string(from: date))
        headers.append("Message-ID: " + clean(messageID))
        if let inReplyTo = inReplyTo.map(clean), !inReplyTo.isEmpty {
            headers.append("In-Reply-To: " + inReplyTo)
            let chain = [references.map(clean) ?? "", inReplyTo].filter { !$0.isEmpty }.joined(separator: " ")
            headers.append("References: " + chain)
        }
        headers += ["MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        let normalized = message.body
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let body = Data(normalized.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func clean(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Non-ASCII subjects become RFC 2047 encoded words, split so each header line stays under 76 characters.
    static func encodedSubject(_ subject: String) -> String {
        let subject = clean(subject)
        guard !subject.allSatisfy(\.isASCII) else { return subject }
        var words: [String] = []
        var chunk = ""
        for character in subject {
            if chunk.utf8.count + String(character).utf8.count > 42 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
