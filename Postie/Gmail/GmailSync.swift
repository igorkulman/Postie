import Foundation
import os

// Separate from basic reading so offline/demo/test readers need not simulate history.
nonisolated protocol GmailSyncReading: GmailReading {
    func currentHistoryID() async throws -> String
    func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage
    func metadata(id: String) async throws -> GmailConversation?
}

nonisolated struct GmailHistoryPage: Decodable, Sendable {
    struct Message: Decodable, Sendable { let id: String; let threadId: String }
    struct Change: Decodable, Sendable { let message: Message }
    struct Record: Decodable, Sendable {
        let id: String
        let messages: [Message]?
        let messagesAdded: [Change]?
        let messagesDeleted: [Change]?
        let labelsAdded: [Change]?
        let labelsRemoved: [Change]?

        var affectedMessages: [Message] {
            (messages ?? []) + [messagesAdded, messagesDeleted, labelsAdded, labelsRemoved]
                .flatMap { ($0 ?? []).map(\.message) }
        }
    }
    let history: [Record]?
    let nextPageToken: String?
    let historyId: String

    var affectedThreadIDs: Set<String> { Set((history ?? []).flatMap(\.affectedMessages).map(\.threadId)) }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.contains { $0 != "0" } && id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // History IDs are opaque decimal strings, not Ints and not contiguous counters.
    static func isAtLeast(_ id: String, _ previous: String) -> Bool {
        let lhs = String(id.drop(while: { $0 == "0" }))
        let rhs = String(previous.drop(while: { $0 == "0" }))
        return lhs.count == rhs.count ? lhs >= rhs : lhs.count > rhs.count
    }
}

nonisolated struct GmailProfile: Decodable, Sendable { let historyId: String }
nonisolated enum GmailSyncError: Error { case historyExpired }

nonisolated struct GmailSyncBatch: Sendable {
    var snapshots: [Mailbox: GmailPage] = [:]
    var conversations: [GmailConversation] = []
    var deletedThreadIDs: Set<String> = []
    let expectedHistoryID: String?
    var historyID: String
}

// The coordinator's bookkeeping stays on the main actor; the network work and merging it starts run off it.
// One owned operation per account reader. Folder switches and overlapping refreshes
// await the same operation; cancelling a view waiter doesn't cancel account sync.
// Reset/sign-out explicitly cancels it. Network work is staged before one DB commit.
@MainActor
final class GmailSyncCoordinator {
    private let api: any GmailSyncReading
    private let cache: GmailCacheSession
    private var running: Task<Void, Error>?
    private var operation = Generation()

    init(api: any GmailSyncReading, cache: GmailCacheSession) {
        self.api = api
        self.cache = cache
    }

    func cancel() {
        running?.cancel()
        running = nil
        operation.advance()
    }

    func synchronize(mailbox: Mailbox) async throws {
        repeat {
            try Task.checkCancellation()
            let request: Generation
            let task: Task<Void, Error>
            if let running {
                request = operation
                task = running
            } else {
                operation.advance()
                request = operation
                task = Task { try await self.perform(mailbox: mailbox) }
                running = task
            }
            do { try await task.value }
            catch {
                if operation == request { running = nil }
                throw error
            }
            if operation == request { running = nil }
            try Task.checkCancellation()
            if mailbox == .outbox { return }
            if try await cache.loadMailbox(mailbox) != nil { return }
            // A folder first opened during another folder's bootstrap needs a
            // snapshot. Recheck the shared operation after this database await.
        } while true
    }

    @concurrent
    private func perform(mailbox: Mailbox) async throws {
        let checkpoint = try await cache.historyID()
        do {
            if let checkpoint {
                var batch = GmailSyncBatch(expectedHistoryID: checkpoint, historyID: checkpoint)
                // Capture history BEFORE initializing a newly visited folder.
                let changes = try await history(since: checkpoint)
                if mailbox != .outbox, try await cache.loadMailbox(mailbox) == nil {
                    batch.snapshots[mailbox] = try await api.mailbox(mailbox, pageToken: nil)
                }
                Log.sync.info("Incremental sync: \(changes.ids.count, privacy: .public) changed threads")
                let fetched = try await metadata(ids: changes.ids)
                batch.conversations = fetched.conversations
                batch.deletedThreadIDs = fetched.deleted
                batch.historyID = changes.checkpoint
                try Task.checkCancellation()
                try await cache.applySync(batch)
            } else {
                Log.sync.info("First sync, taking a full snapshot")
                try await rebuild(mailbox: mailbox, expectedHistoryID: nil)
            }
        } catch GmailSyncError.historyExpired {
            Log.sync.notice("The sync checkpoint expired, rebuilding from a fresh snapshot")
            // Only a history 404 expires the checkpoint; other endpoint errors propagate.
            // A fresh baseline + snapshot + replay replaces an expired checkpoint.
            try await rebuild(mailbox: mailbox, expectedHistoryID: checkpoint)
        }
    }

    @concurrent
    private func rebuild(mailbox: Mailbox, expectedHistoryID: String?) async throws {
        let baseline = try await api.currentHistoryID()
        guard GmailHistoryPage.validID(baseline) else { throw GmailError.invalidResponse }
        var batch = GmailSyncBatch(expectedHistoryID: expectedHistoryID, historyID: baseline)
        var mailboxes = Set(try await cache.cachedMailboxes())
        if mailbox != .outbox { mailboxes.insert(mailbox) }
        for folder in mailboxes.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            batch.snapshots[folder] = try await api.mailbox(folder, pageToken: nil)
        }
        // Reconcile all previously loaded threads, not just the newest snapshot page.
        // Absence from one page is never evidence of account-wide deletion.
        let oldIDs = Set(try await cache.cachedThreadIDs())
        let old = try await metadata(ids: oldIDs)
        let replay = try await history(since: baseline)
        let changed = try await metadata(ids: replay.ids)
        var merged = Dictionary(uniqueKeysWithValues: old.conversations.map { ($0.id, $0) })
        for conversation in changed.conversations { merged[conversation.id] = conversation }
        for id in changed.deleted { merged[id] = nil }
        batch.conversations = Array(merged.values)
        batch.deletedThreadIDs = old.deleted.subtracting(Set(changed.conversations.map(\.id))).union(changed.deleted)
        batch.historyID = replay.checkpoint
        try Task.checkCancellation()
        try await cache.applySync(batch)
    }

    @concurrent
    private func history(since checkpoint: String) async throws -> (ids: Set<String>, checkpoint: String) {
        var ids: Set<String> = []
        var token: String?
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page: GmailHistoryPage
            do { page = try await api.history(startHistoryID: checkpoint, pageToken: token) }
            catch GmailError.http(404) { throw GmailSyncError.historyExpired }
            guard GmailHistoryPage.validID(page.historyId), GmailHistoryPage.isAtLeast(page.historyId, checkpoint),
                  page.affectedThreadIDs.allSatisfy({ !$0.isEmpty }) else { throw GmailError.invalidResponse }
            ids.formUnion(page.affectedThreadIDs)
            token = page.nextPageToken?.isEmpty == false ? page.nextPageToken : nil
            if let token {
                guard seen.insert(token).inserted else { throw GmailError.invalidResponse }
            } else {
                return (ids, page.historyId)
            }
        } while true
    }

    @concurrent
    private func metadata(ids: Set<String>) async throws -> (conversations: [GmailConversation], deleted: Set<String>) {
        let api = api
        return try await withThrowingTaskGroup(of: (String, GmailConversation?).self) { group in
            var iterator = ids.sorted().makeIterator()
            for _ in 0..<min(6, ids.count) {
                if let id = iterator.next() { group.addTask { (id, try await api.metadata(id: id)) } }
            }
            var conversations: [GmailConversation] = []
            var deleted: Set<String> = []
            while let (id, conversation) = try await group.next() {
                try Task.checkCancellation()
                if let conversation {
                    guard conversation.id == id else { throw GmailError.invalidResponse }
                    conversations.append(conversation)
                } else { deleted.insert(id) }
                if let id = iterator.next() { group.addTask { (id, try await api.metadata(id: id)) } }
            }
            return (conversations, deleted)
        }
    }
}

extension GmailConversation {
    nonisolated func belongs(to mailbox: Mailbox) -> Bool {
        switch mailbox {
        case .inbox: labelIDs.contains("INBOX")
        case .drafts: labelIDs.contains("DRAFT")
        case .sent: labelIDs.contains("SENT")
        case .junk: labelIDs.contains("SPAM")
        case .trash: labelIDs.contains("TRASH")
        case .outbox: false
        case .archive:
            labelIDs.isDisjoint(with: ["INBOX", "DRAFT", "SPAM", "TRASH"])
                && messages.contains { $0.labelIDs.isDisjoint(with: ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH"]) }
        }
    }
}
