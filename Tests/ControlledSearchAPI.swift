import Foundation
@testable import Postie

/// Controls only search I/O; paging, cancellation and presentation state stay in the real hub.
@MainActor
final class ControlledSearchAPI: GmailSearching {
    private var pending: CheckedContinuation<GmailPage, Error>?
    private let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private(set) var pageTokens: [String?] = []

    init() {
        (events, started) = AsyncStream.makeStream(of: Void.self)
    }

    func unreadInboxCount() async throws -> Int { 0 }
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: [], nextPageToken: nil)
    }
    func conversation(id: String) async throws -> GmailConversation { throw GmailError.http(404) }

    @MainActor
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        pageTokens.append(pageToken)
        return try await withCheckedThrowingContinuation {
            pending = $0
            started.yield()
        }
    }

    func waitForSearch() async throws {
        if pending != nil { return }
        var iterator = events.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
    }

    func finishSearch(_ page: GmailPage) {
        let request = pending
        pending = nil
        request?.resume(returning: page)
    }

    func finishPendingSearch() {
        let request = pending
        pending = nil
        request?.resume(throwing: CancellationError())
    }
}
