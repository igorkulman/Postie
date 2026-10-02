import Foundation
import Testing
@testable import iMail

nonisolated enum GmailFixtures {
    static func thread(_ id: String = "a1", htmlOnly: Bool = false) -> Data {
        let plain = "Hello Alex,\n\nCoffee tomorrow?"
        let html = "<html><head><style>.hidden{display:none}</style></head><body><p>Hello &amp; goodbye &#x1F44B;</p><img src=\"https://tracking.example.com/pixel\"><script>alert(1)</script></body></html>"
        let headers = [
            ["name": "fRoM", "value": "=?UTF-8?Q?Sophie_Chen?= <sophie@example.com>"],
            ["name": "To", "value": "Alex <alex@example.com>"],
            ["name": "Cc", "value": "james@example.com"],
            ["name": "Subject", "value": "=?UTF-8?B?Q29mZmVlIHBsYW5z?="]
        ]
        var parts: [[String: Any]] = [
            ["mimeType": "text/plain", "filename": "attachment.txt", "body": ["data": Data("Do not show this attachment".utf8).base64EncodedString()]],
            ["mimeType": "text/html", "body": ["data": Data(html.utf8).base64EncodedString()]]
        ]
        if !htmlOnly {
            parts.append(["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=\"UTF-8\""]], "body": ["data": Data(plain.utf8).base64EncodedString()]]
            ]])
        }
        let object: [String: Any] = ["id": id, "messages": [
            ["id": id == "a1" ? "b2" : id + "-b2", "labelIds": ["SENT", "STARRED"], "snippet": "Coffee &amp; plans", "internalDate": "2000000",
             "payload": ["mimeType": "multipart/mixed", "headers": headers, "parts": parts]],
            ["id": id == "a1" ? "b1" : id + "-b1", "labelIds": ["INBOX", "UNREAD", "Label_42"], "snippet": "Earlier message", "internalDate": "1000000",
             "payload": ["mimeType": "text/plain", "headers": headers, "body": ["data": Data("Earlier message".utf8).base64EncodedString()]]]
        ]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func conversation(_ id: String, includeBody: Bool = true) throws -> GmailConversation {
        try JSONDecoder().decode(GmailThreadResource.self, from: thread(id)).conversation(includeBody: includeBody)
    }
}

actor FixtureTransport: GmailTransport {
    enum Mode: Sendable, Equatable { case normal, empty, invalid, denied, missing }
    let mode: Mode
    private(set) var requests: [URLRequest] = []

    init(mode: Mode = .normal) { self.mode = mode }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        switch mode {
        case .denied: return GmailHTTPResponse(data: Data(), statusCode: 401)
        case .invalid: return GmailHTTPResponse(data: Data("not JSON".utf8), statusCode: 200)
        case .missing: return GmailHTTPResponse(data: Data(), statusCode: 404)
        case .empty: return GmailHTTPResponse(data: Data("{}".utf8), statusCode: 200)
        case .normal: break
        }
        let url = request.url!
        if url.path.hasSuffix("/labels/INBOX") {
            return GmailHTTPResponse(data: Data(#"{"id":"INBOX","messagesUnread":1234}"#.utf8), statusCode: 200)
        }
        if url.path.hasSuffix("/threads") {
            return GmailHTTPResponse(data: Data(#"{"threads":[{"id":"a1","snippet":"List &amp; snippet"},{"id":"a1"},{"id":"deleted"}],"nextPageToken":"next +/="}"#.utf8), statusCode: 200)
        }
        if url.lastPathComponent == "deleted" { return GmailHTTPResponse(data: Data(), statusCode: 404) }
        let data = GmailFixtures.thread(url.lastPathComponent)
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value
        if format == "metadata" {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            var messages = object["messages"] as! [[String: Any]]
            for index in messages.indices {
                messages[index].removeValue(forKey: "snippet")
                var payload = messages[index]["payload"] as! [String: Any]
                payload.removeValue(forKey: "body")
                payload.removeValue(forKey: "parts")
                messages[index]["payload"] = payload
            }
            object["messages"] = messages
            return GmailHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
        }
        return GmailHTTPResponse(data: data, statusCode: 200)
    }
}

// An explicit barrier proves that the API limits fan-out without relying on sleeps.
actor ConcurrencyTransport: GmailTransport {
    private var active = 0
    private(set) var maximum = 0
    private var released = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    private let ready: AsyncStream<Void>
    private let readyEvents: AsyncStream<Void>.Continuation

    init() {
        (ready, readyEvents) = AsyncStream.makeStream(of: Void.self)
    }

    func waitForSix() async throws {
        if maximum >= 6 { return }
        var iterator = ready.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    func release() {
        released = true
        let continuations = pending
        pending = []
        continuations.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        let url = request.url!
        if url.path.hasSuffix("/threads") {
            let ids = (1...9).map { ["id": "a\($0)"] }
            return GmailHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["threads": ids]), statusCode: 200)
        }
        active += 1
        maximum = max(maximum, active)
        if maximum >= 6 { readyEvents.yield(); readyEvents.finish() }
        if !released {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() }
                    else { pending.append(continuation) }
                }
            } onCancel: {
                // Cancellation callbacks are synchronous; hop to the transport's actor for cleanup.
                Task { await self.release() }
            }
        }
        active -= 1
        return GmailHTTPResponse(data: GmailFixtures.thread(url.lastPathComponent), statusCode: 200)
    }
}

@MainActor
final class StubAPI: GmailReading {
    var pages: [Result<GmailPage, Error>]
    var tokens: [String?] = []
    var mailboxes: [Mailbox] = []
    var selected: [String] = []
    var failsSelection = false
    var unreadCount: Result<Int, Error> = .success(0)
    var unreadCountCalls = 0

    @MainActor
    func unreadInboxCount() async throws -> Int {
        unreadCountCalls += 1
        return try unreadCount.get()
    }

    init(_ pages: [Result<GmailPage, Error>]) { self.pages = pages }

    @MainActor
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        mailboxes.append(mailbox)
        tokens.append(pageToken)
        guard !pages.isEmpty else { throw GmailError.invalidResponse }
        return try pages.removeFirst().get()
    }

    @MainActor
    func conversation(id: String) async throws -> GmailConversation {
        selected.append(id)
        if failsSelection { throw GmailError.http(503) }
        return try GmailFixtures.conversation(id)
    }
}

@MainActor
final class ControlledAPI: GmailReading {
    var page: CheckedContinuation<GmailPage, Error>?
    var selections: [String: CheckedContinuation<GmailConversation, Error>] = [:]
    private let pageEvents: AsyncStream<Void>
    private let pageStarted: AsyncStream<Void>.Continuation
    private let selectionEvents: AsyncStream<Int>
    private let selectionStarted: AsyncStream<Int>.Continuation
    private var selectionCount = 0

    init() {
        (pageEvents, pageStarted) = AsyncStream.makeStream(of: Void.self)
        (selectionEvents, selectionStarted) = AsyncStream.makeStream(of: Int.self)
    }

    func unreadInboxCount() async throws -> Int { 0 }

    func waitForPage() async throws {
        if page != nil { return }
        var iterator = pageEvents.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    func waitForSelections(_ count: Int) async throws {
        if selectionCount >= count { return }
        for await started in selectionEvents {
            if started >= count { return }
        }
        throw CancellationError()
    }

    @MainActor
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        try await withCheckedThrowingContinuation {
            page = $0
            pageStarted.yield()
        }
    }

    @MainActor
    func conversation(id: String) async throws -> GmailConversation {
        try await withCheckedThrowingContinuation {
            selections[id] = $0
            selectionCount += 1
            selectionStarted.yield(selectionCount)
        }
    }

    func finishPage(_ result: Result<GmailPage, Error>) throws {
        let continuation = try #require(page)
        page = nil
        continuation.resume(with: result)
    }

    func finishSelection(_ id: String, result: Result<GmailConversation, Error>) throws {
        let pending = selections.removeValue(forKey: id)
        let continuation = try #require(pending)
        continuation.resume(with: result)
    }

    func finishPendingRequests() {
        page?.resume(throwing: CancellationError())
        page = nil
        selections.values.forEach { $0.resume(throwing: CancellationError()) }
        selections = [:]
    }
}
