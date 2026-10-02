import Foundation

// Gmail IDs and labels stay intact; the demo's exclusive Mailbox enum is only a UI projection.
nonisolated struct GmailMessage: Identifiable, Equatable, Sendable {
    let id: String
    let senderName: String
    let senderEmail: String
    let recipient: String
    let cc: String
    let date: Date
    let snippet: String
    let body: String
    var bodyLoaded: Bool = true
    var htmlBody: String? = nil
    var labelIDs: Set<String>
}

nonisolated struct GmailConversation: Identifiable, Equatable, Sendable {
    let id: String
    let subject: String
    let messages: [GmailMessage]

    var labelIDs: Set<String> { messages.reduce(into: []) { $0.formUnion($1.labelIDs) } }
    var isUnread: Bool { labelIDs.contains("UNREAD") }
    var isStarred: Bool { labelIDs.contains("STARRED") }
    var latestDate: Date { messages.last?.date ?? .distantPast }

    /// A copy with a label added to or removed from every message, mirroring Gmail's thread-level modify.
    func setting(_ label: String, to on: Bool) -> GmailConversation {
        GmailConversation(id: id, subject: subject, messages: messages.map { message in
            var message = message
            if on { message.labelIDs.insert(label) } else { message.labelIDs.remove(label) }
            return message
        })
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || subject.localizedCaseInsensitiveContains(term) || messages.contains {
            [$0.senderName, $0.senderEmail, $0.recipient, $0.cc, $0.snippet, $0.body].contains {
                $0.localizedCaseInsensitiveContains(term)
            }
        }
    }
}

nonisolated struct GmailPage: Sendable {
    let conversations: [GmailConversation]
    let nextPageToken: String?
}

// REST wire types, isolated from SwiftUI and authentication.
nonisolated struct GmailInboxLabel: Decodable, Sendable {
    let id: String
    let messagesUnread: Int
}

nonisolated struct GmailThreadList: Decodable, Sendable {
    struct Reference: Decodable, Sendable { let id: String; let snippet: String? }
    let threads: [Reference]?
    let nextPageToken: String?
}

nonisolated struct GmailThreadResource: Decodable, Sendable {
    let id: String
    let messages: [Message]?

    struct Message: Decodable, Sendable {
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }

    struct Part: Decodable, Sendable {
        struct Header: Decodable, Sendable { let name: String; let value: String }
        struct Body: Decodable, Sendable { let data: String?; let attachmentId: String? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?

        func header(_ name: String) -> String {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }

        func textParts(ofType mimeType: String) -> [Part] {
            guard (filename ?? "").isEmpty,
                  !header("Content-Disposition").lowercased().hasPrefix("attachment"),
                  self.mimeType?.lowercased() != "message/rfc822" else { return [] }
            if self.mimeType?.lowercased() == mimeType { return [self] }
            return (parts ?? []).flatMap { $0.textParts(ofType: mimeType) }
        }
    }

    func conversation(includeBody: Bool, fallbackSnippet: String? = nil) throws -> GmailConversation {
        guard let messages, !messages.isEmpty else { throw GmailError.invalidResponse }
        let sorted = messages.sorted { (Double($0.internalDate ?? "") ?? 0) < (Double($1.internalDate ?? "") ?? 0) }
        let subject = GmailText.decodeHeader(sorted.first?.payload?.header("Subject") ?? "")
        return try GmailConversation(id: id, subject: subject.isEmpty ? "(No subject)" : subject, messages: sorted.map { message in
            let sender = GmailText.sender(message.payload?.header("From") ?? "")
            let content = includeBody ? try GmailText.content(message.payload) : nil
            return GmailMessage(
                id: message.id, senderName: sender.name, senderEmail: sender.email,
                recipient: GmailText.decodeHeader(message.payload?.header("To") ?? ""),
                cc: GmailText.decodeHeader(message.payload?.header("Cc") ?? ""),
                date: Date(timeIntervalSince1970: (Double(message.internalDate ?? "") ?? 0) / 1000),
                snippet: GmailText.decodeEntities(message.snippet ?? (message.id == sorted.last?.id ? fallbackSnippet : nil) ?? ""),
                body: content?.plainText ?? "", bodyLoaded: includeBody, htmlBody: content?.html,
                labelIDs: Set(message.labelIds ?? [])
            )
        })
    }
}

nonisolated enum GmailError: LocalizedError, Equatable {
    case invalidResponse
    case http(Int)
    case signInRequired
    case permissionRequired

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Gmail returned a response that could not be read."
        case .http(401), .signInRequired: "Your Google session has expired. Sign out and sign in again."
        case .http(403): "Gmail access was denied. Check that the Gmail API is enabled and mail access was granted."
        case .http(429): "Gmail is temporarily rate-limiting requests. Please try again shortly."
        case .http(let code): "Gmail could not complete the request (HTTP \(code)). Try again."
        case .permissionRequired: "Postie needs permission to read and organize your Gmail. Sign in again and allow Gmail access."
        }
    }
}

nonisolated enum GmailText {
    static func base64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func decode(_ data: Data, charset: String) -> String? {
        switch charset.lowercased() {
        case "iso-8859-1", "latin1": String(data: data, encoding: .isoLatin1)
        case "windows-1252": String(data: data, encoding: .windowsCP1252)
        case "us-ascii", "ascii": String(data: data, encoding: .ascii)
        case "utf-16": String(data: data, encoding: .utf16)
        case "utf-8", "utf8", "": String(data: data, encoding: .utf8)
        default: nil
        }
    }

    struct Content: Equatable, Sendable {
        let plainText: String
        let html: String?
    }

    static func body(_ payload: GmailThreadResource.Part?) throws -> String {
        try content(payload).plainText
    }

    static func content(_ payload: GmailThreadResource.Part?) throws -> Content {
        guard let payload else { return Content(plainText: "This message has no readable text body.", html: nil) }
        let plain = try decodedParts(payload, mimeType: "text/plain")
        // A broken optional HTML alternative must not hide an otherwise readable message.
        let html = plain.isEmpty
            ? try decodedParts(payload, mimeType: "text/html")
            : (try? decodedParts(payload, mimeType: "text/html")) ?? []
        let fallback = html.map { plainText(fromHTML: $0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let readable = (plain.isEmpty ? fallback : plain).joined(separator: "\n\n")
        return Content(
            plainText: readable.isEmpty
                ? "The text body is unavailable in this reader. It may use an unsupported encoding or require an attachment download. Open Gmail to view the complete message."
                : readable,
            html: html.isEmpty ? nil : html.joined(separator: "\n<hr>\n")
        )
    }

    private static func decodedParts(_ payload: GmailThreadResource.Part, mimeType: String) throws -> [String] {
        try payload.textParts(ofType: mimeType).compactMap { part in
            guard let encoded = part.body?.data, !encoded.isEmpty else { return nil }
            guard let data = base64URL(encoded) else { throw GmailError.invalidResponse }
            let contentType = part.header("Content-Type")
            let charset = contentType.range(of: #"charset\s*=\s*["']?([^;"'\s]+)"#, options: [.regularExpression, .caseInsensitive])
                .map { String(contentType[$0]).components(separatedBy: "=").last!.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } ?? "utf-8"
            guard let text = decode(data, charset: charset),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }

    // A non-rendering search/fallback conversion. HTML rendering is separately restricted by EmailHTMLPolicy.
    static func plainText(fromHTML html: String) -> String {
        var result = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li|tr|h[1-6])\s*>"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return decodeEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ value: String) -> String {
        var result = value
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#, options: .caseInsensitive) {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: result), let range = Range(match.range, in: result) else { continue }
                let digits = String(result[digitsRange])
                let isHex = digits.lowercased().hasPrefix("x")
                if let number = UInt32(isHex ? String(digits.dropFirst()) : digits, radix: isHex ? 16 : 10), let scalar = UnicodeScalar(number) {
                    result.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    static func decodeHeader(_ value: String) -> String {
        var result = value.replacingOccurrences(of: #"(?<=\?=)\s+(?==\?)"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let contentRange = Range(match.range(at: 3), in: result) else { continue }
            let content = String(result[contentRange])
            let data: Data?
            if result[encodingRange].lowercased() == "b" {
                data = Data(base64Encoded: content)
            } else {
                let bytes = Array(content.utf8)
                var decoded: [UInt8] = []
                var index = 0
                while index < bytes.count {
                    if bytes[index] == 61, index + 2 < bytes.count,
                       let hex = String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii), let byte = UInt8(hex, radix: 16) {
                        decoded.append(byte); index += 3
                    } else {
                        decoded.append(bytes[index] == 95 ? 32 : bytes[index]); index += 1
                    }
                }
                data = Data(decoded)
            }
            if let data, let text = decode(data, charset: String(result[charsetRange])) { result.replaceSubrange(range, with: text) }
        }
        return result
    }

    static func sender(_ value: String) -> (name: String, email: String) {
        let decoded = decodeHeader(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = decoded.lastIndex(of: "<"), let end = decoded[start...].firstIndex(of: ">") {
            let email = String(decoded[decoded.index(after: start)..<end])
            let name = String(decoded[..<start]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (name.isEmpty ? email : name, email)
        }
        return (decoded.isEmpty ? "Unknown sender" : decoded, decoded)
    }
}
