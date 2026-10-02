import Foundation
import Testing
@testable import Postie

@Suite("Gmail reader state", .timeLimit(.minutes(1)))
@MainActor
struct GmailReaderStoreTests {
    @Test("The first page publishes conversations and a continuation token")
    func initialPage() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [a], nextPageToken: "next"))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        #expect(store.conversations.map(\.id) == ["a1"])
        #expect(store.nextPageToken == "next")
        #expect(!store.isLoadingMailbox)
        #expect(store.mailboxError == nil)
    }

    @Test("Failed pagination preserves mail and retries the same token")
    func paginationRetry() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let b = try GmailFixtures.conversation("a2", includeBody: false)
        let api = StubAPI([
            .success(GmailPage(conversations: [a], nextPageToken: "next")),
            .failure(GmailError.http(503)),
            .success(GmailPage(conversations: [a, b], nextPageToken: "next"))
        ])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.loadMore()
        #expect(store.conversations.map(\.id) == ["a1"])
        #expect(store.nextPageToken == "next")
        #expect(store.mailboxError != nil)
        await store.loadMore()
        #expect(store.conversations.map(\.id) == ["a1", "a2"])
        #expect(store.nextPageToken == nil)
        #expect(store.mailboxError == nil)
        #expect(api.tokens.count == 3)
        #expect(api.tokens == [nil, "next", "next"])
    }

    @Test("Loading a body caches it and makes it searchable, leaving read state to the view")
    func bodyCache() async throws {
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [metadata], nextPageToken: nil))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        #expect(store.conversations.first?.matches("tomorrow") == false)
        await store.select("a1")
        await store.select("a1")
        #expect(api.selected == ["a1"])
        #expect(store.selectedConversation?.id == "a1")
        #expect(store.conversations.first?.matches("tomorrow") == true)
        #expect(store.conversations.first?.isUnread == true)
    }

    @Test("Refresh replaces stale entries and invalidates cached bodies")
    func refresh() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let b = try GmailFixtures.conversation("a2", includeBody: false)
        let api = StubAPI([
            .success(GmailPage(conversations: [a, b], nextPageToken: "next")),
            .success(GmailPage(conversations: [a], nextPageToken: nil))
        ])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        await store.refresh()
        #expect(store.conversations.map(\.id) == ["a1"])
        #expect(store.nextPageToken == nil)
        await store.select("a1")
        #expect(api.selected == ["a1", "a1"])
        #expect(api.tokens == [nil, nil])
    }

    @Test("Failed refresh preserves visible mail, pagination and cached bodies")
    func refreshFailure() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([
            .success(GmailPage(conversations: [a], nextPageToken: "next")),
            .failure(GmailError.http(503))
        ])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        let version = store.mailboxVersion
        await store.refresh()
        await store.select("a1")
        #expect(store.conversations.map(\.id) == ["a1"])
        #expect(store.nextPageToken == "next")
        #expect(store.mailboxError != nil)
        #expect(store.mailboxVersion == version)
        #expect(api.selected == ["a1"])
    }

    @Test("Body fetch failures expose retry state and can recover")
    func selectionRetry() async {
        let api = StubAPI([])
        let store = GmailReaderStore(api: api)
        api.failsSelection = true
        await store.select("a1")
        #expect(store.conversationError != nil)
        #expect(store.selectedConversation == nil)
        #expect(!store.isLoadingConversation)
        api.failsSelection = false
        await store.select("a1")
        #expect(store.selectedConversation?.id == "a1")
        #expect(store.conversationError == nil)
    }

    @Test("Sign-out clears visible mail, pagination and the body cache")
    func reset() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [a], nextPageToken: "next"))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        store.reset()
        #expect(store.conversations.isEmpty)
        #expect(store.selectedConversation == nil)
        #expect(store.nextPageToken == nil)
        #expect(store.mailboxError == nil && store.conversationError == nil)
        await store.select("a1")
        #expect(api.selected == ["a1", "a1"])
    }

    @Test("Deselecting clears the reader without discarding its session cache")
    func deselect() async {
        let api = StubAPI([])
        let store = GmailReaderStore(api: api)
        await store.select("a1")
        await store.select(nil)
        #expect(store.selectedConversation == nil)
        #expect(!store.isLoadingConversation)
        #expect(store.conversationError == nil)
        await store.select("a1")
        #expect(api.selected == ["a1"])
    }

    @Test("Load More does nothing without a continuation token")
    func noNextPage() async {
        let api = StubAPI([])
        let store = GmailReaderStore(api: api)
        await store.loadMore()
        #expect(api.tokens.isEmpty)
    }

    @Test("A request finishing after sign-out cannot repopulate mail")
    func staleInboxAfterReset() async throws {
        let a = try GmailFixtures.conversation("a1")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let task = Task { await store.refresh() }
        defer { task.cancel(); api.finishPendingRequests() }
        try await api.waitForPage()
        store.reset()
        try api.finishPage(.success(GmailPage(conversations: [a], nextPageToken: "old")))
        await task.value
        #expect(store.conversations.isEmpty)
        #expect(store.nextPageToken == nil)
    }

    @Test("A slower previous selection cannot overwrite the current conversation")
    func selectionOrdering() async throws {
        let a = try GmailFixtures.conversation("a1")
        let b = try GmailFixtures.conversation("a2")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let first = Task { await store.select("a1") }
        defer { first.cancel(); api.finishPendingRequests() }
        try await api.waitForSelections(1)
        let second = Task { await store.select("a2") }
        defer { second.cancel() }
        try await api.waitForSelections(2)
        try api.finishSelection("a2", result: .success(b))
        await second.value
        try api.finishSelection("a1", result: .success(a))
        await first.value
        #expect(store.selectedConversation?.id == "a2")
        #expect(!store.isLoadingConversation)
    }

    @Test("Cancelled selection publishes neither stale content nor an error")
    func cancelledSelection() async throws {
        let a = try GmailFixtures.conversation("a1")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let task = Task { await store.select("a1") }
        defer { task.cancel(); api.finishPendingRequests() }
        try await api.waitForSelections(1)
        task.cancel()
        try api.finishSelection("a1", result: .success(a))
        await task.value
        #expect(store.selectedConversation == nil)
        #expect(!store.isLoadingConversation)
        #expect(store.conversationError == nil)
    }

    @Test("Folder changes clear mail, selection and pagination, then load the selected folder")
    func folderSwitch() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let b = try GmailFixtures.conversation("a2", includeBody: false)
        let api = StubAPI([
            .success(GmailPage(conversations: [a], nextPageToken: "inbox-next")),
            .success(GmailPage(conversations: [b], nextPageToken: "sent-next")),
            .success(GmailPage(conversations: [a], nextPageToken: nil))
        ])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        let version = store.mailboxVersion
        store.changeMailbox(.sent)
        #expect(store.mailbox == .sent)
        #expect(store.mailboxVersion > version)
        #expect(store.conversations.isEmpty)
        #expect(store.selectedConversation == nil)
        #expect(store.nextPageToken == nil)
        #expect(store.mailboxError == nil && store.conversationError == nil)
        await store.refresh()
        await store.loadMore()
        #expect(api.mailboxes == [.inbox, .sent, .sent])
        #expect(api.tokens == [nil, nil, "sent-next"])
        #expect(store.conversations.map(\.id) == ["a2", "a1"])
    }

    @Test("Reselecting the current folder preserves its loaded mail and cache")
    func sameFolder() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [a], nextPageToken: "next"))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        let version = store.mailboxVersion
        store.changeMailbox(.inbox)
        await store.select("a1")
        #expect(store.mailboxVersion == version)
        #expect(store.conversations.count == 1)
        #expect(store.nextPageToken == "next")
        #expect(api.selected == ["a1"])
    }

    @Test("Outbox stays empty without fetching Gmail")
    func outbox() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [a], nextPageToken: "next"))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        store.changeMailbox(.outbox)
        await store.refresh()
        await store.loadMore()
        #expect(store.mailbox == .outbox)
        #expect(store.conversations.isEmpty)
        #expect(store.nextPageToken == nil)
        #expect(!store.isLoadingMailbox)
        #expect(api.mailboxes == [.inbox])
    }

    @Test("A page finishing after a folder switch cannot repopulate the new folder", arguments: [false, true])
    func stalePageAfterFolderSwitch(fails: Bool) async throws {
        let a = try GmailFixtures.conversation("a1")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let task = Task { await store.refresh() }
        defer { task.cancel(); api.finishPendingRequests() }
        try await api.waitForPage()
        store.changeMailbox(.junk)
        try api.finishPage(fails ? .failure(GmailError.http(503)) : .success(GmailPage(conversations: [a], nextPageToken: "old")))
        await task.value
        #expect(store.mailbox == .junk)
        #expect(store.conversations.isEmpty)
        #expect(store.nextPageToken == nil)
        #expect(store.mailboxError == nil)
        #expect(!store.isLoadingMailbox)
    }

    @Test("A body finishing after a folder switch cannot replace its reader")
    func staleBodyAfterFolderSwitch() async throws {
        let a = try GmailFixtures.conversation("a1")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let task = Task { await store.select("a1") }
        defer { task.cancel(); api.finishPendingRequests() }
        try await api.waitForSelections(1)
        store.changeMailbox(.trash)
        try api.finishSelection("a1", result: .success(a))
        await task.value
        #expect(store.mailbox == .trash)
        #expect(store.selectedConversation == nil)
        #expect(store.conversationError == nil)
        #expect(!store.isLoadingConversation)
    }

    @Test("Reset returns a previously selected folder to Inbox")
    func resetFolder() {
        let store = GmailReaderStore(api: StubAPI([]), mailbox: .sent)
        store.reset()
        #expect(store.mailbox == .inbox)
    }

    @Test("Cancelled refresh publishes neither stale mail nor an error")
    func cancelledRefresh() async throws {
        let a = try GmailFixtures.conversation("a1")
        let api = ControlledAPI()
        let store = GmailReaderStore(api: api)
        let task = Task { await store.refresh() }
        defer { task.cancel(); api.finishPendingRequests() }
        try await api.waitForPage()
        task.cancel()
        try api.finishPage(.success(GmailPage(conversations: [a], nextPageToken: "next")))
        await task.value
        #expect(store.conversations.isEmpty)
        #expect(store.nextPageToken == nil)
        #expect(store.mailboxError == nil)
        #expect(!store.isLoadingMailbox)
    }
}
