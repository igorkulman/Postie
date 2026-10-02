import Foundation
import Testing
@testable import Postie

@Suite("Persistent Gmail cache")
struct GmailCacheTests {
    @Test("Loaded pages, labels, HTML and opened bodies survive database reopening")
    func reopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        let account = CachedGmailAccount(id: "google-account-a", email: "alex@example.com")
        let full = try GmailFixtures.conversation("a1")
        do {
            let cache = try await GmailCache.open(at: url)
            let session = try await cache.session(for: account)
            _ = try await session.savePage(GmailPage(conversations: [try GmailFixtures.conversation("a1", includeBody: false)], nextPageToken: "next"), mailbox: .inbox, refreshing: true)
            try await session.saveConversation(full)
            try await session.saveUnreadCount(42)
        }
        let reopened = try await GmailCache.open(at: url)
        #expect(try await reopened.latestAccount() == account)
        let session = try await reopened.session(for: account)
        let page = try await session.loadMailbox(.inbox)
        #expect(page?.conversations == [full])
        #expect(page?.nextPageToken == "next")
        #expect(try await session.conversation(id: "a1") == full)
        #expect(try await session.unreadCount() == 42)
    }

    @Test("Metadata refresh updates labels while preserving bodies by message ID")
    func metadataMerge() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let full = try GmailFixtures.conversation("a1")
        _ = try await session.savePage(GmailPage(conversations: [full], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        try await session.saveConversation(full)
        var metadata = try GmailFixtures.conversation("a1", includeBody: false)
        metadata = GmailConversation(id: metadata.id, subject: "Updated subject", messages: metadata.messages.map {
            GmailMessage(id: $0.id, senderName: $0.senderName, senderEmail: $0.senderEmail, recipient: $0.recipient,
                         cc: $0.cc, date: $0.date, snippet: $0.snippet, body: "", bodyLoaded: false, labelIDs: ["SENT"])
        })
        let page = try await session.savePage(GmailPage(conversations: [metadata], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        #expect(page.conversations.first?.subject == "Updated subject")
        #expect(page.conversations.first?.messages.last?.body == full.messages.last?.body)
        #expect(page.conversations.first?.messages.last?.htmlBody == full.messages.last?.htmlBody)
        #expect(page.conversations.first?.labelIDs == ["SENT"])
    }

    @Test("Pagination deduplicates threads and a first-page refresh is not a whole-account deletion")
    func pagination() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let a = try GmailFixtures.conversation("a1")
        let b = try GmailFixtures.conversation("a2")
        _ = try await session.savePage(GmailPage(conversations: [a], nextPageToken: "next"), mailbox: .inbox, refreshing: true)
        let page = try await session.savePage(GmailPage(conversations: [a, b], nextPageToken: nil), mailbox: .inbox, refreshing: false)
        #expect(page.conversations.map(\.id) == ["a1", "a2"])
        _ = try await session.savePage(GmailPage(conversations: [a], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        #expect(try await session.loadMailbox(.inbox)?.conversations.map(\.id) == ["a1"])
        #expect(try await session.conversation(id: "a2") == b)
    }

    @Test("Identical Gmail IDs are isolated between accounts and removal revokes old writers")
    func accountIsolation() async throws {
        let cache = try await GmailCache.inMemory()
        let a = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let b = try await cache.session(for: CachedGmailAccount(id: "b", email: "b@example.com"))
        let full = try GmailFixtures.conversation("a1")
        try await a.saveConversation(full)
        #expect(try await b.conversation(id: "a1") == nil)
        try await cache.removeAccount(id: "a")
        await #expect(throws: GmailCacheError.sessionExpired) { try await a.saveConversation(full) }
        #expect(try await b.conversation(id: "a1") == nil)
        let newA = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        #expect(try await newA.conversation(id: "a1") == nil)
    }

    @Test("An empty folder is a persisted snapshot, not an unknown folder")
    func emptyFolder() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        #expect(try await session.loadMailbox(.trash) == nil)
        _ = try await session.savePage(GmailPage(conversations: [], nextPageToken: nil), mailbox: .trash, refreshing: true)
        #expect(try await session.loadMailbox(.trash)?.conversations.isEmpty == true)
    }

    @Test("Replacing a lease prevents obsolete readers from saving new mail")
    func leaseReplacement() async throws {
        let cache = try await GmailCache.inMemory()
        let identity = CachedGmailAccount(id: "a", email: "a@example.com")
        let old = try await cache.session(for: identity)
        let replacement = try await cache.session(for: identity)
        await #expect(throws: GmailCacheError.sessionExpired) { try await old.saveUnreadCount(900) }
        try await replacement.saveUnreadCount(7)
        await old.invalidate()
        #expect(try await replacement.unreadCount() == 7)
    }

    @Test("Draft metadata invalidates mutable bodies and deleted messages are removed")
    func draftAndDeletion() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let full = try GmailFixtures.conversation("a1")
        try await session.saveConversation(full)
        let message = full.messages.last!
        let draft = GmailMessage(id: message.id, senderName: message.senderName, senderEmail: message.senderEmail,
                                 recipient: message.recipient, cc: message.cc, date: message.date, snippet: "Edited draft",
                                 body: "", bodyLoaded: false, labelIDs: ["DRAFT"])
        _ = try await session.savePage(GmailPage(conversations: [GmailConversation(id: "a1", subject: "Draft", messages: [draft])], nextPageToken: nil), mailbox: .drafts, refreshing: true)
        let saved = try #require(try await session.conversation(id: "a1"))
        #expect(saved.messages.count == 1)
        #expect(saved.messages.first?.bodyLoaded == false)
        #expect(saved.messages.first?.body.isEmpty == true)
        #expect(saved.messages.first?.htmlBody == nil)
        #expect(saved.labelIDs == ["DRAFT"])
    }

    @Test("A newly added message remains uncached without destroying older bodies")
    func addedMessage() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let full = try GmailFixtures.conversation("a1")
        try await session.saveConversation(full)
        var messages = try GmailFixtures.conversation("a1", includeBody: false).messages
        messages.append(GmailMessage(id: "new", senderName: "New", senderEmail: "new@example.com", recipient: "a@example.com",
                                     cc: "", date: Date(timeIntervalSince1970: 3000), snippet: "New reply", body: "", bodyLoaded: false, labelIDs: ["INBOX"]))
        _ = try await session.savePage(GmailPage(conversations: [GmailConversation(id: "a1", subject: full.subject, messages: messages)], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        let saved = try #require(try await session.conversation(id: "a1"))
        #expect(saved.messages.count == 3)
        #expect(saved.messages.first?.body == full.messages.first?.body)
        #expect(saved.messages.last?.bodyLoaded == false)
    }
}
