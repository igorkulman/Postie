import Foundation
import os

nonisolated protocol GmailReading: Sendable {
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage
    func conversation(id: String) async throws -> GmailConversation
    func unreadInboxCount() async throws -> Int
}

/// Searches with Gmail's own query syntax. `mailbox` limits the search to one folder; nil searches all mail.
nonisolated protocol GmailSearching: GmailReading {
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage
}

nonisolated protocol GmailAttachmentLoading: Sendable {
    func attachmentData(_ attachment: MailAttachment) async throws -> Data
}

nonisolated protocol GmailMutating: Sendable {
    func archive(threadID: String) async throws
    func trash(threadID: String) async throws
    func setLabel(_ label: String, on: Bool, threadID: String) async throws
}

nonisolated struct GmailHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    /// Seconds Gmail asked us to wait, from a Retry-After header.
    var retryAfter: TimeInterval? = nil

    /// Gmail reports rate limits as 429, or as 403 with a "rate limit" reason.
    var isRateLimited: Bool {
        statusCode == 429 || (statusCode == 403 && String(decoding: data, as: UTF8.self).contains("ateLimitExceeded"))
    }
}

nonisolated protocol GmailTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GmailHTTPResponse
}

nonisolated struct GmailURLTransport: GmailTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        return GmailHTTPResponse(data: data, statusCode: response.statusCode,
                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
}

// Reads are GETs; the only writes are archive and trash. Parsing and networking run off the UI actor.
actor GmailAPI: GmailSyncReading, GmailSearching, GmailMutating, GmailSending, GmailDrafting, GmailSignatureLoading, GmailContactLoading, GmailAttachmentLoading {
    private let transport: any GmailTransport
    private let accessToken: @MainActor @Sendable () async throws -> String
    /// Waits between retries of a rate-limited request.
    private let retryDelays: [TimeInterval]
    // Gmail also limits concurrent requests per user, so only a few run at once.
    private let maximumInFlight = 4
    private var inFlight = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(transport: any GmailTransport = GmailURLTransport(), retryDelays: [TimeInterval] = [1, 3, 9],
         accessToken: @escaping @MainActor @Sendable () async throws -> String) {
        self.transport = transport
        self.retryDelays = retryDelays
        self.accessToken = accessToken
    }

    /// Sends the request, waiting and retrying when Gmail says to slow down. A request that stays
    /// rate-limited comes back as 429 so callers show one clear message.
    private func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        var retries = retryDelays.makeIterator()
        while true {
            try Task.checkCancellation()
            try await acquireSlot()
            let result = await Result { try await transport.send(request) }
            releaseSlot()
            let response = try result.get()
            let endpoint = request.url?.path ?? ""
            guard response.isRateLimited else {
                if (200..<300).contains(response.statusCode) {
                    Log.api.debug("\(request.httpMethod ?? "GET", privacy: .public) \(endpoint) -> \(response.statusCode, privacy: .public)")
                } else {
                    Log.api.error("\(request.httpMethod ?? "GET", privacy: .public) \(endpoint) failed with HTTP \(response.statusCode, privacy: .public)")
                }
                return response
            }
            guard let delay = retries.next() else {
                Log.api.error("Still rate limited on \(endpoint) after \(self.retryDelays.count, privacy: .public) retries, giving up")
                return GmailHTTPResponse(data: response.data, statusCode: 429)
            }
            let wait = min(max(delay, response.retryAfter ?? 0), 60)
            Log.api.warning("Rate limited (HTTP \(response.statusCode, privacy: .public)) on \(endpoint), retrying in \(wait, privacy: .public)s")
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// Waits for one of the few request slots. A cancelled wait leaves the queue instead of holding its place.
    private func acquireSlot() async throws {
        try Task.checkCancellation()
        guard inFlight >= maximumInFlight else {
            inFlight += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot straight to the next waiter, or frees it.
    private func releaseSlot() {
        if waiting.isEmpty { inFlight -= 1 } else { waiting.removeFirst().continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        try await threads(in: mailbox, matching: nil, pageToken: pageToken)
    }

    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        try await threads(in: mailbox, matching: query, pageToken: pageToken)
    }

    private func threads(in mailbox: Mailbox?, matching search: String?, pageToken: String?) async throws -> GmailPage {
        // Outbox is a local send queue, not a Gmail label. Sending is not implemented yet.
        guard mailbox != .outbox else { return GmailPage(conversations: [], nextPageToken: nil) }
        var query = [URLQueryItem(name: "maxResults", value: "25")]
        var terms: [String] = []
        switch mailbox {
        case .inbox: query.append(URLQueryItem(name: "labelIds", value: "INBOX"))
        case .drafts: query.append(URLQueryItem(name: "labelIds", value: "DRAFT"))
        case .sent: query.append(URLQueryItem(name: "labelIds", value: "SENT"))
        case .junk, .trash:
            query.append(URLQueryItem(name: "labelIds", value: mailbox == .junk ? "SPAM" : "TRASH"))
            query.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
        case .archive:
            // Gmail has no ARCHIVE label: use received mail outside the other system folders.
            terms.append("-in:inbox -in:sent -in:drafts -in:spam -in:trash")
        case .outbox, nil: break
        }
        if let search { terms.append(search) }
        if !terms.isEmpty { query.append(URLQueryItem(name: "q", value: terms.joined(separator: " "))) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let page: GmailThreadList = try await get(path: "threads", query: query)
        var seen: Set<String> = []
        let references = (page.threads ?? []).filter { seen.insert($0.id).inserted }
        let conversations = try await withThrowingTaskGroup(of: GmailConversation?.self) { group in
            var iterator = references.makeIterator()
            for _ in 0..<min(6, references.count) {
                if let reference = iterator.next() {
                    group.addTask { try await self.metadata(id: reference.id, fallbackSnippet: reference.snippet) }
                }
            }
            var results: [GmailConversation] = []
            while let result = try await group.next() {
                if let result {
                    // Gmail search is message-based; don't show a still-in-Inbox thread in Archive
                    // just because another message in that thread matched the archive query.
                    let excludedArchiveLabels: Set<String> = ["INBOX", "DRAFT", "SPAM", "TRASH"]
                    if mailbox != .archive || result.labelIDs.isDisjoint(with: excludedArchiveLabels) {
                        results.append(result)
                    }
                }
                if let reference = iterator.next() {
                    group.addTask { try await self.metadata(id: reference.id, fallbackSnippet: reference.snippet) }
                }
            }
            return results.sorted { $0.latestDate > $1.latestDate }
        }
        try Task.checkCancellation()
        return GmailPage(conversations: conversations, nextPageToken: page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil)
    }

    func unreadInboxCount() async throws -> Int {
        // The label's total is independent of pagination and the currently selected folder.
        let label: GmailInboxLabel = try await get(path: "labels/INBOX", query: [
            URLQueryItem(name: "fields", value: "id,messagesUnread")
        ])
        guard label.id == "INBOX", label.messagesUnread >= 0 else { throw GmailError.invalidResponse }
        return label.messagesUnread
    }

    func conversation(id: String) async throws -> GmailConversation {
        let resource: GmailThreadResource = try await get(path: try threadPath(id), query: [URLQueryItem(name: "format", value: "full")])
        guard resource.id == id else { throw GmailError.invalidResponse }
        return try resource.conversation(includeBody: true)
    }

    func currentHistoryID() async throws -> String {
        let profile: GmailProfile = try await get(path: "profile", query: [URLQueryItem(name: "fields", value: "historyId")])
        guard GmailHistoryPage.validID(profile.historyId) else { throw GmailError.invalidResponse }
        return profile.historyId
    }

    func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        guard GmailHistoryPage.validID(startHistoryID) else { throw GmailError.invalidResponse }
        var query = [URLQueryItem(name: "startHistoryId", value: startHistoryID),
                     URLQueryItem(name: "maxResults", value: "500")]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        // No label or history-type filter: moves OUT of Inbox and permanent deletions matter.
        let page: GmailHistoryPage = try await get(path: "history", query: query)
        guard GmailHistoryPage.validID(page.historyId), GmailHistoryPage.isAtLeast(page.historyId, startHistoryID),
              (page.history ?? []).allSatisfy({ record in
                  GmailHistoryPage.validID(record.id) && record.affectedMessages.allSatisfy { !$0.id.isEmpty && !$0.threadId.isEmpty }
              }) else { throw GmailError.invalidResponse }
        return page
    }

    func metadata(id: String) async throws -> GmailConversation? {
        try await metadata(id: id, fallbackSnippet: nil)
    }

    private func metadata(id: String, fallbackSnippet: String?) async throws -> GmailConversation? {
        do {
            // Only the full format lists attachments, so ask for it without any body data.
            let resource: GmailThreadResource = try await get(path: try threadPath(id), query: [
                URLQueryItem(name: "format", value: "full"),
                URLQueryItem(name: "fields", value: Self.listFields)
            ])
            guard resource.id == id else { throw GmailError.invalidResponse }
            return try resource.conversation(includeBody: false, fallbackSnippet: fallbackSnippet)
        } catch GmailError.http(404) {
            // A conversation can disappear between listing and fetching its headers.
            return nil
        }
    }

    /// Headers and the MIME tree's shape, without the (possibly huge) body data.
    private static let listFields: String = {
        let part = "partId,mimeType,filename,headers,body(attachmentId,size)"
        var tree = part
        for _ in 0..<4 { tree = "\(part),parts(\(tree))" }
        return "id,messages(id,labelIds,snippet,internalDate,payload(\(tree)))"
    }()

    func attachmentData(_ attachment: MailAttachment) async throws -> Data {
        do { return try await download(messageID: attachment.messageID, attachmentID: attachment.attachmentID) }
        catch GmailError.http(let code) where code == 404 || code == 400 {
            // Gmail may reissue attachment IDs, so look the file up again by its place in the message.
            Log.attachments.notice("Attachment ID was rejected (HTTP \(code, privacy: .public)), looking it up again")
            let message: GmailThreadResource.Message = try await get(path: try messagePath(attachment.messageID),
                                                                     query: [URLQueryItem(name: "format", value: "full")])
            guard let fresh = message.payload?.attachments(messageID: attachment.messageID)
                .first(where: { $0.partID == attachment.partID }) else { throw GmailError.http(code) }
            return try await download(messageID: fresh.messageID, attachmentID: fresh.attachmentID)
        }
    }

    private func download(messageID: String, attachmentID: String) async throws -> Data {
        struct Body: Decodable, Sendable { let data: String }
        let path = try messagePath(messageID) + "/attachments/" + Self.pathComponent(attachmentID)
        let body: Body = try await get(path: path, query: [])
        guard let data = GmailText.base64URL(body.data) else { throw GmailError.invalidResponse }
        return data
    }

    func archive(threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/modify", body: ["removeLabelIds": ["INBOX"]])
    }

    func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/modify", body: [on ? "addLabelIds" : "removeLabelIds": [label]])
    }

    func send(_ message: OutgoingMessage) async throws {
        try await post(path: "messages/send", json: try await rawMessage(message))
    }

    /// The JSON Gmail takes for a message: the encoded text, and the thread it belongs to.
    private func rawMessage(_ message: OutgoingMessage) async throws -> [String: Any] {
        var inReplyTo: String?
        var references: String?
        if let threadID = message.threadID {
            // Threading needs the Message-ID chain of the message being answered. A draft in the thread is not that message.
            let resource: GmailThreadResource = try await get(path: try threadPath(threadID), query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
                URLQueryItem(name: "metadataHeaders", value: "References")
            ])
            let last = (resource.messages ?? []).filter { !($0.labelIds ?? []).contains("DRAFT") }
                .max { (Double($0.internalDate ?? "") ?? 0) < (Double($1.internalDate ?? "") ?? 0) }
            inReplyTo = last?.payload?.header("Message-ID").nilIfEmpty
            references = last?.payload?.header("References").nilIfEmpty
        }
        let raw = GmailMessageBuilder.base64URL(GmailMessageBuilder.rfc822(message, inReplyTo: inReplyTo, references: references))
        var body: [String: Any] = ["raw": raw]
        if let threadID = message.threadID { body["threadId"] = threadID }
        return body
    }

    func saveDraft(_ message: OutgoingMessage, draftID: String?) async throws -> GmailDraftRef {
        let body = ["message": try await rawMessage(message)]
        let data: Data
        if let draftID {
            data = try await request("PUT", path: "drafts/" + (try Self.pathComponent(draftID)), json: body)
        } else {
            data = try await request("POST", path: "drafts", json: body)
        }
        guard let resource = try? JSONDecoder().decode(GmailDraftResource.self, from: data), let ref = resource.ref
        else { throw GmailError.invalidResponse }
        return ref
    }

    func sendDraft(_ message: OutgoingMessage, draftID: String) async throws {
        let saved = try await saveDraft(message, draftID: draftID)
        _ = try await request("POST", path: "drafts/send", json: ["id": saved.id])
    }

    func draftCount() async throws -> Int {
        struct Label: Decodable, Sendable { let messagesTotal: Int? }
        let label: Label = try await get(path: "labels/DRAFT", query: [URLQueryItem(name: "fields", value: "messagesTotal")])
        guard let total = label.messagesTotal, total >= 0 else { throw GmailError.invalidResponse }
        return total
    }

    func deleteDraft(id: String) async throws {
        do { _ = try await request("DELETE", path: "drafts/" + (try Self.pathComponent(id)), json: nil) }
        // Already gone, perhaps deleted in another client.
        catch GmailError.http(404) {}
    }

    func draftID(forMessage messageID: String) async throws -> String? {
        var pageToken: String?
        var seen: Set<String> = []
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100"),
                         URLQueryItem(name: "fields", value: "nextPageToken,drafts(id,message(id))")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailDraftList = try await get(path: "drafts", query: query)
            if let found = page.drafts?.first(where: { $0.message?.id == messageID }) { return found.id }
            pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
            if let pageToken, !seen.insert(pageToken).inserted { throw GmailError.invalidResponse }
        } while pageToken != nil
        return nil
    }

    func draftContent(id: String) async throws -> GmailDraftContent {
        let resource: GmailDraftResource = try await get(path: "drafts/" + (try Self.pathComponent(id)), query: [
            URLQueryItem(name: "format", value: "full")
        ])
        guard resource.id == id, let ref = resource.ref, let message = resource.message else { throw GmailError.invalidResponse }
        let payload = message.payload
        let content = try GmailText.content(payload)
        func header(_ name: String) -> String { GmailText.decodeHeader(payload?.header(name) ?? "") }
        return GmailDraftContent(
            ref: ref, subject: header("Subject"), to: header("To"), cc: header("Cc"), bcc: header("Bcc"),
            text: content.plainText, html: content.html, attachments: payload?.attachments(messageID: message.id) ?? [],
            isReply: !(payload?.header("In-Reply-To") ?? "").isEmpty
        )
    }

    func contacts() async throws -> [DirectoryContact] {
        struct Page: Decodable, Sendable {
            struct Person: Decodable, Sendable {
                struct Name: Decodable, Sendable { let displayName: String? }
                struct Address: Decodable, Sendable { let value: String? }
                let names: [Name]?
                let emailAddresses: [Address]?
            }
            let connections: [Person]?
            let otherContacts: [Person]?
            let nextPageToken: String?
        }
        func fetch(path: String, fields: URLQueryItem, saved: Bool) async throws -> [DirectoryContact] {
            var result: [DirectoryContact] = []
            var pageToken: String?
            var seen: Set<String> = []
            repeat {
                var query = [fields, URLQueryItem(name: "pageSize", value: "1000")]
                if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let page: Page = try await get(path: path, query: query, base: "https://people.googleapis.com/v1/")
                for person in (saved ? page.connections : page.otherContacts) ?? [] {
                    let name = person.names?.first?.displayName ?? ""
                    for address in person.emailAddresses ?? [] {
                        if let email = address.value, !email.isEmpty { result.append(DirectoryContact(name: name, email: email, isSaved: saved)) }
                    }
                }
                pageToken = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
                if let pageToken, !seen.insert(pageToken).inserted { throw GmailError.invalidResponse }
            } while pageToken != nil
            return result
        }
        return try await fetch(path: "people/me/connections", fields: URLQueryItem(name: "personFields", value: "names,emailAddresses"), saved: true)
            + fetch(path: "otherContacts", fields: URLQueryItem(name: "readMask", value: "names,emailAddresses"), saved: false)
    }

    func signature() async throws -> String {
        let list: GmailSendAsList = try await get(path: "settings/sendAs", query: [
            URLQueryItem(name: "fields", value: "sendAs(sendAsEmail,isPrimary,isDefault,signature)")
        ])
        return list.signature
    }

    func trash(threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/trash", body: [:])
    }

    private func post(path: String, body: [String: [String]]) async throws {
        try await post(path: path, json: body)
    }

    private func post(path: String, json body: [String: Any]) async throws {
        _ = try await request("POST", path: path, json: body)
    }

    /// A write to Gmail. Returns the response body, which is empty for a delete.
    private func request(_ method: String, path: String, json body: [String: Any]?) async throws -> Data {
        try Task.checkCancellation()
        let token = try await accessToken()
        try Task.checkCancellation()
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path) else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let response = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw GmailError.http(response.statusCode) }
        return response.data
    }

    private func threadPath(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw GmailError.invalidResponse
        }
        return "threads/" + id
    }

    private func messagePath(_ id: String) throws -> String {
        "messages/" + (try Self.pathComponent(id))
    }

    private static func pathComponent(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw GmailError.invalidResponse
        }
        return id
    }

    private func get<Value: Decodable & Sendable>(path: String, query: [URLQueryItem],
                                                  base: String = "https://gmail.googleapis.com/gmail/v1/users/me/") async throws -> Value {
        try Task.checkCancellation()
        let token = try await accessToken()
        try Task.checkCancellation()
        var components = URLComponents(string: base + path)!
        components.queryItems = query
        // Form-style query decoders treat a literal + as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw GmailError.http(response.statusCode) }
        // Gmail answers 204 with no body for an empty list, such as the drafts of an account without any.
        let body = response.data.isEmpty ? Data("{}".utf8) : response.data
        do { return try JSONDecoder().decode(Value.self, from: body) }
        catch { throw GmailError.invalidResponse }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
