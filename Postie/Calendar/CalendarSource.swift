import Foundation

/// A calendar MIME part. Inline bytes and download references both survive the mail cache.
nonisolated struct CalendarSource: Codable, Equatable, Sendable {
    let partID: String
    let data: Data?
    let attachment: MailAttachment?
    let method: String?

    static let maximumBytes = 1_000_000

    /// Older caches retained downloadable files before they knew about calendar MIME parts.
    static func fromAttachments(_ attachments: [MailAttachment]) -> [CalendarSource] {
        attachments.compactMap { attachment in
            let type = attachment.mimeType.lowercased().split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces)
            guard type == "text/calendar" || attachment.filename.lowercased().hasSuffix(".ics") else { return nil }
            return CalendarSource(partID: attachment.partID, data: nil, attachment: attachment, method: nil)
        }
    }

    @concurrent
    static func readFile(_ url: URL) async throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw CalendarInvitationError.unsupported }
        return try Data(contentsOf: url)
    }
}

extension GmailThreadResource.Part {
    nonisolated func calendarSources(messageID: String) -> [CalendarSource] {
        // An attached/forwarded email is not an invitation to the receiving account.
        guard mimeType?.lowercased() != "message/rfc822" else { return [] }
        let type = (mimeType ?? "").lowercased().split(separator: ";").first.map(String.init)
        if type == "text/calendar" || (filename ?? "").lowercased().hasSuffix(".ics") {
            let parameters = header("Content-Type").components(separatedBy: ";").dropFirst()
            let method = parameters.first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("method=") }
                .flatMap { $0.split(separator: "=", maxSplits: 1).last }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")).uppercased() }
            let name = filename.flatMap { $0.isEmpty ? nil : $0 } ?? "invite.ics"
            let attachment = body?.attachmentId.map {
                MailAttachment(messageID: messageID, partID: partId ?? "", attachmentID: $0,
                               filename: name,
                               mimeType: "text/calendar", size: body?.size ?? 0)
            }
            return [CalendarSource(partID: partId ?? "", data: body?.data.flatMap(GmailText.base64URL),
                                   attachment: attachment, method: method)]
        }
        return (parts ?? []).flatMap { $0.calendarSources(messageID: messageID) }
    }
}
