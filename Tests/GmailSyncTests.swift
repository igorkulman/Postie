import Foundation
import Testing
@testable import iMail

@Suite("Incremental Gmail synchronization", .timeLimit(.minutes(1)))
@MainActor
struct GmailSyncTests {
    private let account = CachedGmailAccount(id: "sync-user", email: "alex@example.com")

    private func session() async throws -> GmailCacheSession {
        let cache = try await GmailCache.inMemory()
        return try await cache.session(for: account)
    }

    private func seed(_ session: GmailCacheSession, folders: [Mailbox: GmailPage], checkpoint: String = "100") async throws {
        try await session.applySync(GmailSyncBatch(snapshots: folders, expectedHistoryID: nil, historyID: checkpoint))
    }

    @Test("Initial sync captures a baseline before the snapshot and replays intervening arrivals")
    func initialSnapshot() async throws {
        let cache = try await session()
        let api = SyncTestAPI()
        api.pages[.inbox] = [.success(GmailPage(conversations: [try GmailFixtures.conversation("a1", includeBody: false)], nextPageToken: "older"))]
        api.histories = [.success(syncHistory(ids: ["a2"], checkpoint: "102"))]
        api.metadataResults["a2"] = .success(try GmailFixtures.conversation("a2", includeBody: false))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(api.events.first == "profile")
        #expect(api.events.firstIndex(of: "mailbox:Inbox")! < api.events.firstIndex(of: "history:100")!)
        #expect(try await cache.historyID() == "102")
        #expect(Set(try await cache.loadMailbox(.inbox)!.conversations.map(\.id)) == ["a1", "a2"])
        #expect(try await cache.loadMailbox(.inbox)?.nextPageToken == "older")
    }

    @Test("Every history page is consumed, changed threads are deduplicated, and opened bodies survive")
    func paginatedHistory() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: "older")])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "105", token: "next +/=")),
                         .success(syncHistory(ids: ["a1", "a2"], checkpoint: "110"))]
        api.metadataResults["a1"] = .success(try GmailFixtures.conversation("a1", includeBody: false))
        api.metadataResults["a2"] = .success(try GmailFixtures.conversation("a2", includeBody: false))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(api.historyRequests.map(\.0) == ["100", "100"])
        #expect(api.historyRequests.map(\.1) == [nil, "next +/="])
        #expect(api.metadataCalls.sorted() == ["a1", "a2"])
        #expect(api.mailboxCalls.isEmpty && api.profileCalls == 0)
        #expect(try await cache.conversation(id: "a1") == full)
        #expect(try await cache.historyID() == "110")
        #expect(try await cache.loadMailbox(.inbox)?.nextPageToken == "older")
    }

    @Test("Moving out of Inbox updates every loaded folder, read/star labels, and cached bodies")
    func movedThread() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: nil),
                                       .archive: GmailPage(conversations: [], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "101"))]
        api.metadataResults["a1"] = .success(try relabeled("a1", labels: ["STARRED", "Label_custom"]))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(try await cache.loadMailbox(.inbox)?.conversations.isEmpty == true)
        let archived = try #require(try await cache.loadMailbox(.archive)?.conversations.first)
        #expect(archived.isStarred && !archived.isUnread)
        #expect(archived.labelIDs == ["STARRED", "Label_custom"])
        #expect(archived.messages.map(\.body) == full.messages.map(\.body))
        #expect(archived.messages.allSatisfy { $0.bodyLoaded })
    }

    @Test("Permanent thread deletion cascades through cached messages and folder membership")
    func deletedThread() async throws {
        let cache = try await session()
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [try GmailFixtures.conversation("a1")], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "101"))]
        api.metadataResults["a1"] = .success(nil)
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(try await cache.conversation(id: "a1") == nil)
        #expect(try await cache.loadMailbox(.inbox)?.conversations.isEmpty == true)
        #expect(try await cache.historyID() == "101")
    }

    @Test("A deleted message is removed while remaining downloaded messages survive")
    func deletedMessage() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: nil)])
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "101"))]
        api.metadataResults["a1"] = .success(GmailConversation(id: "a1", subject: full.subject, messages: [metadata.messages[0]]))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(try await cache.conversation(id: "a1")?.messages == [full.messages[0]])
    }

    @Test("Interrupted paging or metadata failure keeps both cache and checkpoint unchanged", arguments: [false, true])
    func interrupted(metadataFailure: Bool) async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: "older")])
        let api = SyncTestAPI()
        if metadataFailure {
            api.histories = [.success(syncHistory(ids: ["a1", "a2"], checkpoint: "110"))]
            api.metadataResults["a1"] = .success(try relabeled("a1", labels: ["TRASH"]))
            api.metadataResults["a2"] = .failure(GmailError.http(503))
        } else {
            api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "105", token: "next")), .failure(GmailError.http(503))]
        }
        await #expect(throws: GmailError.http(503)) { try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox) }
        #expect(try await cache.historyID() == "100")
        #expect(try await cache.loadMailbox(.inbox)?.conversations == [full])
        #expect(try await cache.loadMailbox(.inbox)?.nextPageToken == "older")
    }

    @Test("Expired history rebuilds loaded folders and reconciles older cached threads before checkpoint replacement")
    func expiredHistory() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: "older"),
                                       .trash: GmailPage(conversations: [], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.baseline = "200"
        api.histories = [.failure(GmailError.http(404)), .success(syncHistory(ids: ["a2"], checkpoint: "205"))]
        api.pages[.inbox] = [.success(GmailPage(conversations: [], nextPageToken: nil))]
        api.pages[.trash] = [.success(GmailPage(conversations: [], nextPageToken: nil))]
        api.metadataResults["a1"] = .success(try relabeled("a1", labels: ["TRASH"]))
        api.metadataResults["a2"] = .success(try GmailFixtures.conversation("a2", includeBody: false))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        #expect(api.historyRequests.map(\.0) == ["100", "200"])
        #expect(Set(api.mailboxCalls) == [.inbox, .trash])
        #expect(try await cache.loadMailbox(.inbox)?.conversations.map(\.id) == ["a2"])
        #expect(try await cache.loadMailbox(.trash)?.conversations.first?.messages.map(\.body) == full.messages.map(\.body))
        #expect(try await cache.historyID() == "205")
    }

    @Test("A failed expired-history rebuild retains usable mail and the old checkpoint")
    func failedRebuild() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.baseline = "200"
        api.histories = [.failure(GmailError.http(404)), .failure(GmailError.http(503))]
        api.metadataResults["a1"] = .success(nil)
        await #expect(throws: GmailError.http(503)) { try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox) }
        #expect(try await cache.historyID() == "100")
        #expect(try await cache.conversation(id: "a1") == full)
        #expect(try await cache.loadMailbox(.inbox)?.conversations == [full])
    }

    @Test("Repeated page tokens are rejected without advancing history")
    func repeatingToken() async throws {
        let cache = try await session()
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: [], checkpoint: "101", token: "repeat")),
                         .success(syncHistory(ids: [], checkpoint: "102", token: "repeat"))]
        await #expect(throws: GmailError.invalidResponse) { try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox) }
        #expect(try await cache.historyID() == "100")
    }

    @Test("Account reset cancellation cannot commit a late history response")
    func cancelledSync() async throws {
        let cache = try await session()
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.pausesHistory = true
        let coordinator = GmailSyncCoordinator(api: api, cache: cache)
        let request = Task { try await coordinator.synchronize(mailbox: .inbox) }
        defer { coordinator.cancel(); api.finishPending() }
        await api.waitForHistory()
        coordinator.cancel()
        api.finishHistory(.success(syncHistory(ids: [], checkpoint: "200")))
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await cache.historyID() == "100")
    }

    @Test("Overlapping refreshes share one operation even if a view waiter is cancelled", arguments: [false, true])
    func coalescing(cancelFirst: Bool) async throws {
        let cache = try await session()
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [], nextPageToken: nil)])
        let api = SyncTestAPI()
        api.pausesHistory = true
        let coordinator = GmailSyncCoordinator(api: api, cache: cache)
        let first = Task { try await coordinator.synchronize(mailbox: .inbox) }
        defer { coordinator.cancel(); api.finishPending() }
        await api.waitForHistory()
        let (events, started) = AsyncStream.makeStream(of: Void.self)
        let second = Task { started.yield(); try await coordinator.synchronize(mailbox: .inbox) }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        if cancelFirst { first.cancel() }
        api.finishHistory(.success(syncHistory(ids: [], checkpoint: "101")))
        if cancelFirst { await #expect(throws: CancellationError.self) { try await first.value } }
        else { try await first.value }
        try await second.value
        #expect(try await cache.historyID() == "101")
        #expect(api.historyRequests.count == 1)
    }

    @Test("A stale body or page cannot overwrite a newer committed sync")
    func staleWrites() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: nil)])
        let checkpoint = try await cache.checkpoint()
        try await cache.applySync(GmailSyncBatch(conversations: [try relabeled("a1", labels: ["TRASH"])], expectedHistoryID: "100", historyID: "101"))
        await #expect(throws: GmailCacheError.checkpointChanged) { try await cache.saveConversation(full, checkpoint: checkpoint) }
        await #expect(throws: GmailCacheError.checkpointChanged) {
            _ = try await cache.savePage(GmailPage(conversations: [full], nextPageToken: "old"), mailbox: .inbox, refreshing: false, checkpoint: checkpoint)
        }
        #expect(try await cache.conversation(id: "a1")?.labelIDs == ["TRASH"])
        #expect(try await cache.historyID() == "101")
    }

    @Test("The sync checkpoint survives database reopening and is isolated by account")
    func checkpointDurability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        do {
            let db = try await GmailCache.open(at: url)
            let cache = try await db.session(for: account)
            try await seed(cache, folders: [.inbox: GmailPage(conversations: [], nextPageToken: nil)], checkpoint: "18446744073709551615")
        }
        let db = try await GmailCache.open(at: url)
        let cache = try await db.session(for: account)
        let other = try await db.session(for: CachedGmailAccount(id: "other", email: "other@example.com"))
        #expect(try await cache.historyID() == "18446744073709551615")
        #expect(try await other.historyID() == nil)
        #expect(try await other.loadMailbox(.inbox) == nil)
    }

    @Test("A database error rolls back preceding metadata changes and the checkpoint")
    func transactionRollback() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: "older")])
        // SQLite treats a bound NaN as NULL, violating messages.date's NOT NULL
        // constraint after the first thread has already been updated.
        let invalid = GmailConversation(id: "a2", subject: "Invalid", messages: [
            GmailMessage(id: "invalid-message", senderName: "Test", senderEmail: "test@example.com",
                         recipient: "alex@example.com", cc: "", date: Date(timeIntervalSince1970: .nan),
                         snippet: "", body: "", bodyLoaded: false, labelIDs: ["INBOX"])
        ])
        let snapshot = GmailPage(conversations: [try relabeled("a1", labels: ["TRASH"]), invalid], nextPageToken: nil)
        await #expect(throws: (any Error).self) {
            try await cache.applySync(GmailSyncBatch(snapshots: [.inbox: snapshot], expectedHistoryID: "100", historyID: "101"))
        }
        #expect(try await cache.historyID() == "100")
        #expect(try await cache.conversation(id: "a1") == full)
        #expect(try await cache.conversation(id: "a2") == nil)
        #expect(try await cache.loadMailbox(.inbox)?.conversations == [full])
        #expect(try await cache.loadMailbox(.inbox)?.nextPageToken == "older")
    }

    @Test("A new reply preserves older bodies and marks only the new message as undownloaded")
    func newReply() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: nil)])
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        let reply = GmailMessage(id: "new-reply", senderName: "Alex", senderEmail: "alex@example.com",
                                 recipient: "sam@example.com", cc: "", date: full.latestDate.addingTimeInterval(10),
                                 snippet: "New reply", body: "", bodyLoaded: false, labelIDs: ["INBOX", "UNREAD"])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "101"))]
        api.metadataResults["a1"] = .success(GmailConversation(id: "a1", subject: full.subject, messages: metadata.messages + [reply]))
        try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox)
        let saved = try #require(try await cache.conversation(id: "a1"))
        #expect(Array(saved.messages.dropLast()) == full.messages)
        #expect(saved.messages.last == reply)
        #expect(saved.isUnread)
    }

    @Test("A first-page folder request failure is not misclassified as expired history")
    func folder404() async throws {
        let cache = try await session()
        let api = SyncTestAPI()
        api.pages[.inbox] = [.failure(GmailError.http(404))]
        await #expect(throws: GmailError.http(404)) { try await GmailSyncCoordinator(api: api, cache: cache).synchronize(mailbox: .inbox) }
        #expect(api.profileCalls == 1)
        #expect(try await cache.historyID() == nil)
        #expect(try await cache.loadMailbox(.inbox) == nil)
    }

    @Test("An empty background sync keeps the open reader and layout revision unchanged")
    func unchangedReader() async throws {
        let cache = try await session()
        let full = try GmailFixtures.conversation("a1")
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [full], nextPageToken: "older")])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: [], checkpoint: "101"))]
        let reader = GmailReaderStore(api: api, cache: cache)
        await reader.restoreCachedMailbox()
        await reader.select("a1")
        let version = reader.mailboxVersion
        await reader.refresh()
        #expect(reader.mailboxVersion == version)
        #expect(reader.selectedConversation == full)
        #expect(reader.nextPageToken == "older")
        #expect(try await cache.historyID() == "101")
    }

    @Test("Reader refresh uses history instead of reloading a cached first page")
    func readerIntegration() async throws {
        let cache = try await session()
        try await seed(cache, folders: [.inbox: GmailPage(conversations: [try GmailFixtures.conversation("a1")], nextPageToken: "older")])
        let api = SyncTestAPI()
        api.histories = [.success(syncHistory(ids: ["a1"], checkpoint: "101"))]
        api.metadataResults["a1"] = .success(try relabeled("a1", labels: ["INBOX", "STARRED"]))
        let reader = GmailReaderStore(api: api, cache: cache)
        await reader.restoreCachedMailbox()
        await reader.select("a1")
        await reader.refresh()
        #expect(reader.conversations.first?.isStarred == true)
        #expect(reader.conversations.first?.isUnread == false)
        #expect(reader.selectedConversation?.isStarred == true)
        #expect(reader.unreadInboxCount == 42)
        #expect(api.mailboxCalls.isEmpty)
        #expect(reader.mailboxError == nil)
        #expect(reader.nextPageToken == "older")
    }
}

@MainActor
private func relabeled(_ id: String, labels: Set<String>) throws -> GmailConversation {
    let original = try GmailFixtures.conversation(id, includeBody: false)
    return GmailConversation(id: id, subject: original.subject, messages: original.messages.map {
        GmailMessage(id: $0.id, senderName: $0.senderName, senderEmail: $0.senderEmail, recipient: $0.recipient,
                     cc: $0.cc, date: $0.date, snippet: $0.snippet, body: "", bodyLoaded: false, labelIDs: labels)
    })
}

private nonisolated func syncHistory(ids: [String], checkpoint: String, token: String? = nil) -> GmailHistoryPage {
    GmailHistoryPage(history: ids.map {
        GmailHistoryPage.Record(id: checkpoint, messages: [.init(id: "message-" + $0, threadId: $0)], messagesAdded: nil,
                                messagesDeleted: nil, labelsAdded: nil, labelsRemoved: nil)
    }, nextPageToken: token, historyId: checkpoint)
}

@MainActor
private final class SyncTestAPI: GmailSyncReading {
    var baseline = "100"
    var pages: [Mailbox: [Result<GmailPage, Error>]] = [:]
    var histories: [Result<GmailHistoryPage, Error>] = []
    var metadataResults: [String: Result<GmailConversation?, Error>] = [:]
    var events: [String] = []
    var mailboxCalls: [Mailbox] = []
    var metadataCalls: [String] = []
    var historyRequests: [(String, String?)] = []
    var profileCalls = 0
    var pausesHistory = false
    private var pending: CheckedContinuation<GmailHistoryPage, Error>?
    private let historyEvents: AsyncStream<Void>
    private let historyStarted: AsyncStream<Void>.Continuation

    init() { (historyEvents, historyStarted) = AsyncStream.makeStream(of: Void.self) }

    @MainActor func currentHistoryID() async throws -> String { profileCalls += 1; events.append("profile"); return baseline }
    @MainActor func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        events.append("history:" + startHistoryID)
        historyRequests.append((startHistoryID, pageToken))
        if pausesHistory {
            return try await withCheckedThrowingContinuation { pending = $0; historyStarted.yield() }
        }
        guard !histories.isEmpty else { throw GmailError.invalidResponse }
        return try histories.removeFirst().get()
    }
    @MainActor func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        events.append("mailbox:" + mailbox.rawValue)
        mailboxCalls.append(mailbox)
        guard var queued = pages[mailbox], !queued.isEmpty else { return GmailPage(conversations: [], nextPageToken: nil) }
        let result = queued.removeFirst()
        pages[mailbox] = queued
        return try result.get()
    }
    @MainActor func metadata(id: String) async throws -> GmailConversation? {
        metadataCalls.append(id)
        guard let result = metadataResults[id] else { throw GmailError.invalidResponse }
        return try result.get()
    }
    @MainActor func conversation(id: String) async throws -> GmailConversation { try GmailFixtures.conversation(id) }
    @MainActor func unreadInboxCount() async throws -> Int { 42 }

    func waitForHistory() async {
        if pending != nil { return }
        var iterator = historyEvents.makeAsyncIterator()
        _ = await iterator.next()
    }
    func finishHistory(_ result: Result<GmailHistoryPage, Error>) { pending?.resume(with: result); pending = nil }
    func finishPending() { pending?.resume(throwing: CancellationError()); pending = nil }
}
