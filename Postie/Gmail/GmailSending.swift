import Foundation
import UniformTypeIdentifiers

nonisolated struct OutgoingMessage: Sendable, Equatable {
    var from: String
    var to: String
    var cc: String = ""
    var bcc: String = ""
    var subject: String
    var body: String
    var attachments: [OutgoingAttachment] = []
    /// Gmail thread to attach a reply to. Forwards and new messages start a new thread.
    var threadID: String?
}

nonisolated struct OutgoingAttachment: Sendable, Equatable {
    var filename: String
    var mimeType: String
    var data: Data
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
        if !message.bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { headers.append("Bcc: " + clean(message.bcc)) }
        headers.append("Subject: " + encodedSubject(message.subject))
        headers.append("Date: " + dateFormatter.string(from: date))
        headers.append("Message-ID: " + clean(messageID))
        if let inReplyTo = inReplyTo.map(clean), !inReplyTo.isEmpty {
            headers.append("In-Reply-To: " + inReplyTo)
            let chain = [references.map(clean) ?? "", inReplyTo].filter { !$0.isEmpty }.joined(separator: " ")
            headers.append("References: " + chain)
        }
        headers.append("MIME-Version: 1.0")
        let text = encodedBody(message.body)
        let textHeaders = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64"
        guard !message.attachments.isEmpty else {
            headers.append(textHeaders)
            return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + text + "\r\n").utf8)
        }
        let boundary = "postie-" + UUID().uuidString
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var out = headers.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\n" + textHeaders + "\r\n\r\n" + text + "\r\n"
        for attachment in message.attachments {
            let name = headerParameter(attachment.filename)
            out += "--\(boundary)\r\n"
            out += "Content-Type: \(clean(attachment.mimeType)); name=\(name)\r\n"
            out += "Content-Disposition: attachment; filename=\(name)\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n"
            out += wrapped(attachment.data) + "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    private static func encodedBody(_ body: String) -> String {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        return wrapped(Data(normalized.utf8))
    }

    private static func wrapped(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// A quoted, ASCII-safe parameter value. Non-ASCII names use the RFC 2047 form most mail clients understand.
    private static func headerParameter(_ name: String) -> String {
        let cleaned = clean(name).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "'")
        if cleaned.allSatisfy(\.isASCII) { return "\"" + cleaned + "\"" }
        return "\"=?UTF-8?B?" + Data(cleaned.utf8).base64EncodedString() + "?=\""
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

/// Reads the files a person attached to a draft.
nonisolated enum OutgoingAttachments {
    /// Gmail rejects messages over 25 MB, and base64 adds a third on top of the files themselves.
    static let maxTotalBytes = 18_000_000

    struct TooLarge: LocalizedError {
        var errorDescription: String? {
            String(localized: "The attachments are too large. Gmail allows about 18 MB of files in one message.")
        }
    }

    @concurrent
    static func load(_ urls: [URL]) async throws -> [OutgoingAttachment] {
        var total = 0
        var result: [OutgoingAttachment] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            total += data.count
            guard total <= maxTotalBytes else { throw TooLarge() }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            result.append(OutgoingAttachment(
                filename: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data
            ))
        }
        return result
    }
}
