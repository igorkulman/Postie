import Foundation

nonisolated protocol GmailReading: Sendable {
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage
    func conversation(id: String) async throws -> GmailConversation
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

// Only exposes GET operations. Parsing and networking run off the UI actor.
actor GmailAPI: GmailReading {
    private let transport: any GmailTransport
    private let accessToken: @MainActor @Sendable () async throws -> String

    init(transport: any GmailTransport = GmailURLTransport(),
         accessToken: @escaping @MainActor @Sendable () async throws -> String) {
        self.transport = transport
        self.accessToken = accessToken
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        // Outbox is a local send queue, not a Gmail label. Sending is not implemented yet.
        guard mailbox != .outbox else { return GmailPage(conversations: [], nextPageToken: nil) }
        var query = [URLQueryItem(name: "maxResults", value: "25")]
        switch mailbox {
        case .inbox: query.append(URLQueryItem(name: "labelIds", value: "INBOX"))
        case .drafts: query.append(URLQueryItem(name: "labelIds", value: "DRAFT"))
        case .sent: query.append(URLQueryItem(name: "labelIds", value: "SENT"))
        case .junk, .trash:
            query.append(URLQueryItem(name: "labelIds", value: mailbox == .junk ? "SPAM" : "TRASH"))
            query.append(URLQueryItem(name: "includeSpamTrash", value: "true"))
        case .archive:
            // Gmail has no ARCHIVE label: use received mail outside the other system folders.
            query.append(URLQueryItem(name: "q", value: "-in:inbox -in:sent -in:drafts -in:spam -in:trash"))
        case .outbox: break
        }
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

    func conversation(id: String) async throws -> GmailConversation {
        let resource: GmailThreadResource = try await get(path: try threadPath(id), query: [URLQueryItem(name: "format", value: "full")])
        guard resource.id == id else { throw GmailError.invalidResponse }
        return try resource.conversation(includeBody: true)
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
