import Foundation

nonisolated protocol GmailReading: Sendable {
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage
    func conversation(id: String) async throws -> GmailConversation
    func unreadInboxCount() async throws -> Int
}

/// Searches with Gmail's own query syntax. `mailbox` limits the search to one folder; nil searches all mail.
nonisolated protocol GmailSearching: GmailReading {
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage
}

nonisolated protocol GmailMutating: Sendable {
    func archive(threadID: String) async throws
    func trash(threadID: String) async throws
    func setLabel(_ label: String, on: Bool, threadID: String) async throws
}

nonisolated struct GmailHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
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
        return GmailHTTPResponse(data: data, statusCode: response.statusCode)
    }
}

// Reads are GETs; the only writes are archive and trash. Parsing and networking run off the UI actor.
actor GmailAPI: GmailSyncReading, GmailSearching, GmailMutating, GmailSending {
    private let transport: any GmailTransport
    private let accessToken: @MainActor @Sendable () async throws -> String

    init(transport: any GmailTransport = GmailURLTransport(),
         accessToken: @escaping @MainActor @Sendable () async throws -> String) {
        self.transport = transport
        self.accessToken = accessToken
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
            let resource: GmailThreadResource = try await get(path: try threadPath(id), query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "From"),
                URLQueryItem(name: "metadataHeaders", value: "To"),
                URLQueryItem(name: "metadataHeaders", value: "Cc"),
                URLQueryItem(name: "metadataHeaders", value: "Subject")
            ])
            guard resource.id == id else { throw GmailError.invalidResponse }
            return try resource.conversation(includeBody: false, fallbackSnippet: fallbackSnippet)
        } catch GmailError.http(404) {
            // A conversation can disappear between listing and fetching its headers.
            return nil
        }
    }

    func archive(threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/modify", body: ["removeLabelIds": ["INBOX"]])
    }

    func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/modify", body: [on ? "addLabelIds" : "removeLabelIds": [label]])
    }

    func send(_ message: OutgoingMessage) async throws {
        var inReplyTo: String?
        var references: String?
        if let threadID = message.threadID {
            // Threading needs the Message-ID chain of the message being answered.
            let resource: GmailThreadResource = try await get(path: try threadPath(threadID), query: [
                URLQueryItem(name: "format", value: "metadata"),
                URLQueryItem(name: "metadataHeaders", value: "Message-ID"),
                URLQueryItem(name: "metadataHeaders", value: "References")
            ])
            let last = (resource.messages ?? []).max { (Double($0.internalDate ?? "") ?? 0) < (Double($1.internalDate ?? "") ?? 0) }
            inReplyTo = last?.payload?.header("Message-ID").nilIfEmpty
            references = last?.payload?.header("References").nilIfEmpty
        }
        let raw = GmailMessageBuilder.base64URL(GmailMessageBuilder.rfc822(message, inReplyTo: inReplyTo, references: references))
        var body = ["raw": raw]
        if let threadID = message.threadID { body["threadId"] = threadID }
        try await post(path: "messages/send", json: body)
    }

    func trash(threadID: String) async throws {
        try await post(path: try threadPath(threadID) + "/trash", body: [:])
    }

    private func post(path: String, body: [String: [String]]) async throws {
        try await post(path: path, json: body)
    }

    private func post(path: String, json body: [String: Any]) async throws {
        try Task.checkCancellation()
        let token = try await accessToken()
        try Task.checkCancellation()
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path) else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GmailError.http(response.statusCode) }
    }

    private func threadPath(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw GmailError.invalidResponse
        }
        return "threads/" + id
    }

    private func get<Value: Decodable & Sendable>(path: String, query: [URLQueryItem]) async throws -> Value {
        try Task.checkCancellation()
        let token = try await accessToken()
        try Task.checkCancellation()
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        components.queryItems = query
        // Form-style query decoders treat a literal + as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw GmailError.http(response.statusCode) }
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw GmailError.invalidResponse }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
