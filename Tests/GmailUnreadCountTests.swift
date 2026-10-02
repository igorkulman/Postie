import Foundation
import Testing
@testable import Postie

@Suite("Gmail unread Inbox total", .timeLimit(.minutes(1)))
struct GmailUnreadCountAPITests {
    @Test("Fetch the total unread messages, not unread threads or loaded rows")
    func totalCount() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        #expect(try await api.unreadInboxCount() == 1234)
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/gmail/v1/users/me/labels/INBOX")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query == [URLQueryItem(name: "fields", value: "id,messagesUnread")])
    }

    @Test("An Inbox with no unread messages returns zero")
    func zeroCount() async throws {
        let api = GmailAPI(transport: InboxCountTransport(body: #"{"id":"INBOX","messagesUnread":0}"#)) { "fixture-token" }
        #expect(try await api.unreadInboxCount() == 0)
    }

    @Test("Malformed or inconsistent counts cannot clear a valid badge", arguments: [
        "not JSON", "{}", #"{"id":"SENT","messagesUnread":5}"#,
        #"{"id":"INBOX","messagesUnread":-1}"#, #"{"id":"INBOX"}"#
    ])
    func invalidCount(body: String) async {
        let api = GmailAPI(transport: InboxCountTransport(body: body)) { "fixture-token" }
        await #expect(throws: GmailError.invalidResponse) { try await api.unreadInboxCount() }
    }

    @Test("Count requests preserve HTTP failures")
    func countFailure() async {
        let api = GmailAPI(transport: InboxCountTransport(body: "", status: 503)) { "fixture-token" }
        await #expect(throws: GmailError.http(503)) { try await api.unreadInboxCount() }
    }
}

@Suite("Unread badge state", .timeLimit(.minutes(1)))
@MainActor
struct GmailUnreadCountStoreTests {
    @Test("Refresh gets the full count even while viewing Sent; pagination and reading leave it unchanged")
    func refreshAndPagination() async throws {
        let message = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([
            .success(GmailPage(conversations: [message], nextPageToken: "next")),
            .success(GmailPage(conversations: [], nextPageToken: nil))
        ])
        api.unreadCount = .success(1234)
        let store = GmailReaderStore(api: api, mailbox: .sent)
        #expect(store.unreadInboxCount == nil)
        await store.refresh()
        #expect(store.unreadInboxCount == 1234)
        #expect(store.conversations.count == 1)
        await store.loadMore()
        await store.select("a1")
        #expect(store.unreadInboxCount == 1234)
        #expect(api.unreadCountCalls == 1)
    }

    @Test("Folder changes retain the account's count; reset clears it")
    func folderAndAccountChanges() async {
        let api = StubAPI([])
        api.unreadCount = .success(42)
        let store = GmailReaderStore(api: api)
        await store.refreshUnreadCount()
        for mailbox in Mailbox.allCases {
            store.changeMailbox(mailbox)
            #expect(store.unreadInboxCount == 42)
        }
        store.reset()
        #expect(store.unreadInboxCount == nil)
    }

    @Test("Failed count refresh preserves the previous count; a successful zero clears it")
    func failureAndZero() async {
        let api = StubAPI([])
        let store = GmailReaderStore(api: api)
        api.unreadCount = .success(42)
        await store.refreshUnreadCount()
        api.unreadCount = .failure(GmailError.http(503))
        await store.refreshUnreadCount()
        #expect(store.unreadInboxCount == 42)
        api.unreadCount = .success(0)
        await store.refreshUnreadCount()
        #expect(store.unreadInboxCount == 0)
        #expect(DockBadge.label(forUnreadCount: store.unreadInboxCount) == nil)
    }

    @Test("Badge failures don't prevent mailbox refresh")
    func independentFailure() async {
        let api = StubAPI([.success(GmailPage(conversations: [], nextPageToken: nil))])
        api.unreadCount = .failure(GmailError.http(503))
        let store = GmailReaderStore(api: api)
        await store.refresh()
        #expect(store.mailboxError == nil)
        #expect(store.mailboxVersion == 1)
        #expect(store.unreadInboxCount == nil)
    }

    @Test("A count finishing after account reset cannot restore the old badge")
    func staleAfterReset() async throws {
        let api = ControlledUnreadAPI()
        let store = GmailReaderStore(api: api)
        let request = Task { await store.refreshUnreadCount() }
        defer { request.cancel(); api.finishPending() }
        try await api.waitForRequests(1)
        store.reset()
        try api.finish(1, count: 900)
        await request.value
        #expect(store.unreadInboxCount == nil)
    }

    @Test("Account reset also invalidates the mailbox refresh's child badge request")
    func resetDuringMailboxRefresh() async throws {
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let request = Task { await store.refresh() }
        defer { request.cancel(); api.finishPendingRequests() }
        try await api.waitForPage()
        store.reset()
        try api.finishPage(.success(GmailPage(conversations: [], nextPageToken: nil)))
        await request.value
        #expect(store.unreadInboxCount == nil)
    }

    @Test("A slower count request cannot replace the latest refresh")
    func requestOrdering() async throws {
        let api = ControlledUnreadAPI()
        let store = GmailReaderStore(api: api)
        let first = Task { await store.refreshUnreadCount() }
        defer { first.cancel(); api.finishPending() }
        try await api.waitForRequests(1)
        let second = Task { await store.refreshUnreadCount() }
        defer { second.cancel() }
        try await api.waitForRequests(2)
        try api.finish(2, count: 7)
        await second.value
        try api.finish(1, count: 900)
        await first.value
        #expect(store.unreadInboxCount == 7)
    }

    @Test("Cancellation cannot publish a count or change the badge")
    func cancelledCount() async throws {
        let api = ControlledUnreadAPI()
        let store = GmailReaderStore(api: api)
        let request = Task { await store.refreshUnreadCount() }
        defer { request.cancel(); api.finishPending() }
        try await api.waitForRequests(1)
        request.cancel()
        try api.finish(1, count: 900)
        await request.value
        #expect(store.unreadInboxCount == nil)
    }
}

private struct InboxCountTransport: GmailTransport {
    let body: String
    var status = 200

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        GmailHTTPResponse(data: Data(body.utf8), statusCode: status)
    }
}

@MainActor
private final class ControlledUnreadAPI: GmailReading {
    private var pending: [Int: CheckedContinuation<Int, Error>] = [:]
    private var requestCount = 0
    private let started: AsyncStream<Int>
    private let events: AsyncStream<Int>.Continuation

    init() { (started, events) = AsyncStream.makeStream(of: Int.self) }

    func waitForRequests(_ count: Int) async throws {
        if requestCount >= count { return }
        for await number in started {
            if number >= count { return }
        }
        throw CancellationError()
    }

    @MainActor
    func unreadInboxCount() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            pending[requestCount] = continuation
            events.yield(requestCount)
        }
    }

    func finish(_ request: Int, count: Int) throws {
        let value = pending.removeValue(forKey: request)
        let continuation = try #require(value)
        continuation.resume(returning: count)
    }

    func finishPending() {
        pending.values.forEach { $0.resume(throwing: CancellationError()) }
        pending = [:]
        events.finish()
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: [], nextPageToken: nil)
    }

    func conversation(id: String) async throws -> GmailConversation { throw GmailError.invalidResponse }
}
