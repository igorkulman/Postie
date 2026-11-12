import Foundation
import Testing
@testable import Postie

@Suite("Gmail network recovery", .timeLimit(.minutes(1)))
struct GmailNetworkRecoveryTests {
    private actor Transport: GmailTransport {
        private var failures: [URLError.Code]
        private(set) var requests: [URLRequest] = []
        private let cancelOnFailure: Bool
        private let failingPathSuffix: String?

        init(_ failures: [URLError.Code], cancelOnFailure: Bool = false, failingPathSuffix: String? = nil) {
            self.failures = failures
            self.cancelOnFailure = cancelOnFailure
            self.failingPathSuffix = failingPathSuffix
        }

        func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
            requests.append(request)
            if !failures.isEmpty, failingPathSuffix.map({ request.url?.path.hasSuffix($0) == true }) ?? true {
                if cancelOnFailure { withUnsafeCurrentTask { $0?.cancel() } }
                throw URLError(failures.removeFirst())
            }
            if request.url?.path.hasSuffix("/drafts/d1") == true {
                return GmailHTTPResponse(data: Data(#"{"id":"d1","message":{"id":"m1","threadId":"a1"}}"#.utf8), statusCode: 200)
            }
            return GmailHTTPResponse(data: Data(#"{"id":"INBOX","messagesUnread":7}"#.utf8), statusCode: 200)
        }
    }

    @Test("A transient read failure recovers without reaching the reader UI", arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func readRecovers(code: URLError.Code) async throws {
        let transport = Transport([code])
        let api = GmailAPI(transport: transport) { "token" }
        #expect(try await api.unreadInboxCount() == 7)
        #expect(await transport.requests.count == 2)
    }

    @Test("A transient automatic refresh preserves mail without an immediate error banner")
    @MainActor
    func refreshStaysQuiet() async throws {
        let conversation = try GmailFixtures.conversation("a1")
        let api = StubAPI([
            .success(GmailPage(conversations: [conversation], nextPageToken: "older")),
            .failure(URLError(.timedOut))
        ])
        let reader = GmailReaderStore(api: api)
        await reader.refresh()
        await reader.select("a1")
        let refreshedAt = reader.lastRefreshed
        await reader.refresh()
        #expect(reader.mailboxError == nil)
        #expect(reader.conversations == [conversation])
        #expect(reader.selectedConversation == conversation)
        #expect(reader.nextPageToken == "older")
        #expect(reader.lastRefreshed == refreshedAt)
        #expect(reader.showingCachedMail)
    }

    @Test("Safe mutations retry the same request after a lost response", arguments: [0, 1, 2])
    func mutationRecovers(operation: Int) async throws {
        let transport = Transport([.networkConnectionLost])
        let api = GmailAPI(transport: transport, networkRetryDelays: [0]) { "token" }
        switch operation {
        case 0: try await api.archive(threadID: "a1")
        case 1: try await api.trash(threadID: "a1")
        default: try await api.setLabel("UNREAD", on: false, threadID: "a1")
        }
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.first == requests.last)
    }

    @Test("A continuing connection failure stops after one recovery attempt")
    func boundedRetry() async {
        let transport = Transport([.timedOut, .networkConnectionLost])
        let api = GmailAPI(transport: transport, networkRetryDelays: [0]) { "token" }
        await #expect(throws: URLError(.networkConnectionLost)) { try await api.unreadInboxCount() }
        #expect(await transport.requests.count == 2)
    }

    @Test("Cancellation and non-transient errors are never retried", arguments: [URLError.Code.cancelled, .secureConnectionFailed])
    func noRetry(code: URLError.Code) async {
        let transport = Transport([code])
        let api = GmailAPI(transport: transport, networkRetryDelays: [0]) { "token" }
        await #expect(throws: URLError(code)) { try await api.unreadInboxCount() }
        #expect(await transport.requests.count == 1)
    }

    @Test("A task cancelled during a transport failure cannot issue another request")
    func cancelledRecovery() async {
        let transport = Transport([.timedOut], cancelOnFailure: true)
        let api = GmailAPI(transport: transport, networkRetryDelays: [0]) { "token" }
        let task = Task { try await api.unreadInboxCount() }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }

    @Test("A lost send or draft-write response is not replayed", arguments: [0, 1, 2, 3])
    func unsafeWritesAreNotRetried(operation: Int) async {
        let transport = Transport([.timedOut], failingPathSuffix: operation == 3 ? "/drafts/send" : nil)
        let api = GmailAPI(transport: transport, networkRetryDelays: [0]) { "token" }
        let message = OutgoingMessage(from: "alex@example.com", to: "sophie@example.com", subject: "Hello", body: "Test")
        await #expect(throws: URLError(.timedOut)) {
            if operation == 0 { try await api.send(message) }
            else if operation == 3 { try await api.sendDraft(message, draftID: "d1") }
            else { _ = try await api.saveDraft(message, draftID: operation == 1 ? nil : "d1") }
        }
        let requests = await transport.requests
        #expect(requests.count == (operation == 3 ? 2 : 1))
        if operation == 3 { #expect(requests.filter { $0.url?.path.hasSuffix("/drafts/send") == true }.count == 1) }
    }

    @Test("Repeated automatic failures surface and a successful refresh resets the failure streak")
    @MainActor
    func persistentFailures() async throws {
        let page = GmailPage(conversations: [try GmailFixtures.conversation("a1")], nextPageToken: nil)
        let api = StubAPI([
            .success(page), .failure(URLError(.timedOut)), .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)), .success(page), .failure(URLError(.timedOut))
        ])
        let reader = GmailReaderStore(api: api)
        await reader.refresh()
        for _ in 0..<2 {
            await reader.refresh()
            #expect(reader.mailboxError == nil)
        }
        await reader.refresh()
        #expect(reader.mailboxError != nil)
        #expect(reader.conversations == page.conversations)
        await reader.refresh()
        #expect(reader.mailboxError == nil)
        #expect(!reader.showingCachedMail)
        await reader.refresh()
        #expect(reader.mailboxError == nil)
    }

    @Test("An empty previously fetched mailbox is still usable during a transient refresh failure")
    @MainActor
    func emptyMailbox() async {
        let api = StubAPI([.success(GmailPage(conversations: [], nextPageToken: nil)), .failure(URLError(.timedOut))])
        let reader = GmailReaderStore(api: api)
        await reader.refresh()
        await reader.refresh()
        #expect(reader.mailboxError == nil)
        #expect(reader.showingCachedMail)
    }

    @Test("Initial loading, explicit refresh, pagination and permission errors remain visible", arguments: [0, 1, 2, 3])
    @MainActor
    func actionableFailures(scenario: Int) async throws {
        let api = StubAPI([])
        let reader = GmailReaderStore(api: api)
        if scenario != 0 {
            api.pages = [.success(GmailPage(conversations: [try GmailFixtures.conversation("a1")], nextPageToken: "older"))]
            await reader.refresh()
        }
        api.pages = [.failure(scenario == 3 ? GmailError.http(403) : URLError(.timedOut))]
        if scenario == 2 { await reader.loadMore() }
        else { await reader.refresh(isUserInitiated: scenario == 1) }
        #expect(reader.mailboxError != nil)
    }

    @Test("URLSession cancellation is not turned into a refresh banner")
    @MainActor
    func cancelledRefresh() async {
        let reader = GmailReaderStore(api: StubAPI([.failure(URLError(.cancelled))]))
        await reader.refresh()
        #expect(reader.mailboxError == nil)
    }
}
