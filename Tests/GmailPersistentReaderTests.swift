import Foundation
import Testing
@testable import iMail

@Suite("Cache-backed Gmail reader", .timeLimit(.minutes(1)))
@MainActor
struct GmailPersistentReaderTests {
    private let account = CachedGmailAccount(id: "test-user", email: "alex@example.com")

    @Test("Relaunch shows saved rows, opened HTML bodies and unread count without any network requests")
    func offlineRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        do {
            let database = try await GmailCache.open(at: url)
            let session = try await database.session(for: account)
            let metadata = try GmailFixtures.conversation("a1", includeBody: false)
            let api = StubAPI([.success(GmailPage(conversations: [metadata], nextPageToken: "next"))])
            api.unreadCount = .success(42)
            let reader = GmailReaderStore(api: api, cache: session)
            await reader.refresh()
            await reader.select("a1")
            #expect(api.selected == ["a1"])
        }
        let database = try await GmailCache.open(at: url)
        let session = try await database.session(for: account)
        let offline = StubAPI([])
        offline.failsSelection = true
        offline.unreadCount = .failure(GmailError.http(503))
        let reader = GmailReaderStore(api: offline, cache: session)
        await reader.restoreCachedMailbox()
        #expect(reader.conversations.map(\.id) == ["a1"])
        #expect(reader.nextPageToken == "next")
        #expect(reader.unreadInboxCount == 42)
        #expect(reader.showingCachedMail)
        #expect(reader.lastRefreshed != nil)
        #expect(offline.mailboxes.isEmpty && offline.unreadCountCalls == 0)
        await reader.select("a1")
        #expect(reader.selectedConversation?.messages.last?.body == "Hello Alex,\n\nCoffee tomorrow?")
        #expect(reader.selectedConversation?.messages.last?.htmlBody != nil)
        #expect(offline.selected.isEmpty)
        await reader.refresh()
        #expect(reader.mailboxError != nil)
        #expect(reader.conversations.count == 1)
        #expect(reader.unreadInboxCount == 42)
        #expect(reader.selectedConversation != nil)
    }

    @Test("Folder switches reuse persisted bodies instead of downloading them again")
    func folderSwitch() async throws {
        let database = try await GmailCache.inMemory()
        let session = try await database.session(for: account)
        let full = try GmailFixtures.conversation("a1")
        for mailbox in [Mailbox.inbox, .sent] {
            _ = try await session.savePage(GmailPage(conversations: [full], nextPageToken: nil), mailbox: mailbox, refreshing: true)
        }
        let api = StubAPI([])
        api.failsSelection = true
        let reader = GmailReaderStore(api: api, cache: session)
        await reader.restoreCachedMailbox()
        await reader.select("a1")
        reader.changeMailbox(.sent)
        await reader.restoreCachedMailbox()
        await reader.select("a1")
        #expect(reader.conversations.count == 1)
        #expect(reader.selectedConversation == full)
        #expect(api.selected.isEmpty)
    }

    @Test("Online metadata refresh preserves downloaded bodies and updates the visible labels")
    func successfulRefresh() async throws {
        let database = try await GmailCache.inMemory()
        let session = try await database.session(for: account)
        let full = try GmailFixtures.conversation("a1")
        _ = try await session.savePage(GmailPage(conversations: [full], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        let api = StubAPI([.success(GmailPage(conversations: [metadata], nextPageToken: nil))])
        let reader = GmailReaderStore(api: api, cache: session)
        await reader.restoreCachedMailbox()
        await reader.refresh()
        await reader.select("a1")
        #expect(reader.conversations == [full])
        #expect(reader.selectedConversation == full)
        #expect(!reader.showingCachedMail)
        #expect(api.selected.isEmpty)
    }

    @Test("An unopened email shows an offline explanation, not an empty body or discarded cache")
    func unopenedEmail() async throws {
        let database = try await GmailCache.inMemory()
        let session = try await database.session(for: account)
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        _ = try await session.savePage(GmailPage(conversations: [metadata], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        let api = StubAPI([])
        api.failsSelection = true
        let reader = GmailReaderStore(api: api, cache: session)
        await reader.restoreCachedMailbox()
        await reader.select("a1")
        let selected = try #require(reader.selectedConversation)
        #expect(reader.conversationError != nil)
        #expect(selected.messages.allSatisfy { !$0.bodyLoaded })
        let projected = selected.presentation(includingBodies: true)
        #expect(projected.messages.last?.body.contains("has not been downloaded") == true)
        #expect(projected.messages.last?.body.contains(metadata.messages.last!.snippet) == true)
    }

    @Test("A cancelled or obsolete network page is never persisted", arguments: [false, true])
    func stalePage(cancelled: Bool) async throws {
        let database = try await GmailCache.inMemory()
        let session = try await database.session(for: account)
        let api = ControlledAPI()
        let reader = GmailReaderStore(api: api, cache: session)
        let request = Task { await reader.refresh() }
        defer { request.cancel(); api.finishPendingRequests() }
        try await api.waitForPage()
        if cancelled { request.cancel() } else { reader.reset() }
        try api.finishPage(.success(GmailPage(conversations: [try GmailFixtures.conversation("a1")], nextPageToken: "old")))
        await request.value
        #expect(try await session.loadMailbox(.inbox) == nil)
        #expect(reader.conversations.isEmpty)
    }

    @Test("A body finishing after a folder change is not persisted or published")
    func staleBody() async throws {
        let database = try await GmailCache.inMemory()
        let session = try await database.session(for: account)
        let api = ControlledAPI()
        let reader = GmailReaderStore(api: api, cache: session)
        let request = Task { await reader.select("a1") }
        defer { request.cancel(); api.finishPendingRequests() }
        try await api.waitForSelections(1)
        reader.changeMailbox(.sent)
        try api.finishSelection("a1", result: .success(try GmailFixtures.conversation("a1")))
        await request.value
        #expect(try await session.conversation(id: "a1") == nil)
        #expect(reader.selectedConversation == nil)
    }
}
