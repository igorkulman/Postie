import Foundation
import Testing
@testable import Postie

@Suite("Gmail labels", .timeLimit(.minutes(1)))
struct GmailLabelTests {
    private func conversation(_ labels: Set<String>...) -> GmailConversation {
        GmailConversation(id: "thread", subject: "Subject", messages: labels.enumerated().map { index, labels in
            GmailMessage(id: "message-\(index)", senderName: "Sender", senderEmail: "sender@example.com", recipient: "alex@example.com",
                         cc: "", date: Date(timeIntervalSince1970: Double(index)), snippet: "", body: "", labelIDs: labels)
        })
    }

    @Test("The folder comes first, then the person's own labels by name, from every message")
    func visibleLabels() {
        let names = ["Label_1": "Safety", "Label_2": "Follow up", "Label_3": "Not on this conversation"]
        let labels = conversation(["INBOX", "Label_1"], ["Label_2"]).visibleLabels(named: names)
        #expect(labels == [Mailbox.inbox.title, "Follow up", "Safety"])
    }

    @Test("States, categories and other system labels are not shown")
    func hiddenLabels() {
        let labels = conversation(["UNREAD", "STARRED", "IMPORTANT", "SENT", "DRAFT", "OUTBOX", "CATEGORY_UPDATES"])
        #expect(labels.visibleLabels(named: [:]).isEmpty)
    }

    @Test("A label whose name is not known yet is left out rather than shown as an ID")
    func unknownLabel() {
        #expect(conversation(["TRASH", "Label_9"]).visibleLabels(named: [:]) == [Mailbox.trash.title])
        #expect(conversation(["SPAM"]).visibleLabels(named: [:]) == [Mailbox.junk.title])
    }

    @Test("Only labels the person created are read from Gmail")
    func listRequest() async throws {
        let transport = LabelTransport(body: #"""
        {"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"Label_1","name":"Safety","type":"user"},
        {"id":"Label_2","name":"Work/Clients","type":"user"}]}
        """#)
        let api = GmailAPI(transport: transport) { "fixture-token" }
        #expect(try await api.userLabels() == ["Label_1": "Safety", "Label_2": "Work/Clients"])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/gmail/v1/users/me/labels")
    }

    @Test("Saved names are replaced as a whole and kept per account")
    func cache() async throws {
        let cache = try await GmailCache.inMemory()
        let first = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let second = try await cache.session(for: CachedGmailAccount(id: "b", email: "b@example.com"))
        try await first.saveLabelNames(["Label_1": "Old", "Label_2": "Removed"])
        try await second.saveLabelNames(["Label_1": "Other account"])
        try await first.saveLabelNames(["Label_1": "Renamed"])
        #expect(try await first.labelNames() == ["Label_1": "Renamed"])
        #expect(try await second.labelNames() == ["Label_1": "Other account"])
    }

    @Test("A refresh picks names up, and they outlive a failed request through the cache")
    @MainActor
    func store() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let online = GmailReaderStore(api: LabelReader(names: ["Label_1": "Safety"]), cache: session)
        await online.refresh()
        #expect(online.labelNames == ["Label_1": "Safety"])

        let offline = GmailReaderStore(api: LabelReader(names: nil), cache: session)
        await offline.refresh()
        #expect(offline.labelNames == ["Label_1": "Safety"])

        offline.reset()
        #expect(offline.labelNames.isEmpty)
    }
}

private actor LabelTransport: GmailTransport {
    let body: String
    private(set) var requests: [URLRequest] = []

    init(body: String) { self.body = body }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        return GmailHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }
}

/// An account with no mail, whose labels can be read only when `names` is set.
private struct LabelReader: GmailReading, GmailLabelLoading {
    let names: [String: String]?

    func userLabels() async throws -> [String: String] {
        guard let names else { throw GmailError.http(503) }
        return names
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage { GmailPage(conversations: [], nextPageToken: nil) }
    func conversation(id: String) async throws -> GmailConversation { throw GmailError.http(404) }
    func unreadInboxCount() async throws -> Int { 0 }
}
