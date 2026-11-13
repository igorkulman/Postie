import Foundation
@testable import Postie

/// Controls network completion only; the real hub owns optimistic state and navigation.
@MainActor
final class ControlledRemovalAPI: GmailSearching, GmailMutating {
    var page: GmailPage
    var holdsMailbox = false
    var holdsSearch = false
    private var removals: [String: CheckedContinuation<Void, Error>] = [:]
    private var mailboxRequest: CheckedContinuation<GmailPage, Error>?
    private var searchRequest: CheckedContinuation<GmailPage, Error>?
    private let events: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation

    init(_ conversations: [GmailConversation]) {
        page = GmailPage(conversations: conversations, nextPageToken: nil)
        (events, started) = AsyncStream.makeStream(of: Void.self)
    }

    @MainActor
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        guard holdsMailbox else { return page }
        return try await withCheckedThrowingContinuation {
            mailboxRequest = $0
            started.yield()
        }
    }

    @MainActor
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        guard holdsSearch else { return page }
        return try await withCheckedThrowingContinuation {
            searchRequest = $0
            started.yield()
        }
    }

    @MainActor
    func conversation(id: String) async throws -> GmailConversation {
        guard let conversation = page.conversations.first(where: { $0.id == id }) else { throw GmailError.http(404) }
        return conversation
    }

    func unreadInboxCount() async throws -> Int { 0 }
    func setLabel(_ label: String, on: Bool, threadID: String) async throws {}
    func archive(threadID: String) async throws { try await remove(threadID) }
    func trash(threadID: String) async throws { try await remove(threadID) }

    private func remove(_ id: String) async throws {
        try await withCheckedThrowingContinuation {
            removals[id] = $0
            started.yield()
        }
    }

    func waitForRemoval(_ id: String) async {
        var iterator = events.makeAsyncIterator()
        while removals[id] == nil { _ = await iterator.next() }
    }

    func waitForMailbox() async {
        var iterator = events.makeAsyncIterator()
        while mailboxRequest == nil { _ = await iterator.next() }
    }

    func waitForSearch() async {
        var iterator = events.makeAsyncIterator()
        while searchRequest == nil { _ = await iterator.next() }
    }

    func finishRemoval(_ id: String, result: Result<Void, Error>) {
        removals.removeValue(forKey: id)?.resume(with: result)
    }

    func finishMailbox(_ page: GmailPage) {
        let request = mailboxRequest
        mailboxRequest = nil
        request?.resume(returning: page)
    }

    func finishSearch(_ page: GmailPage) {
        let request = searchRequest
        searchRequest = nil
        request?.resume(returning: page)
    }
}
