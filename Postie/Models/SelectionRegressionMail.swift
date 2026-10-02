import Foundation
import Observation

/// A deterministic, entirely local Gmail account. Uses real SQLite/history sync, never real credentials.
@MainActor
@Observable
final class SelectionRegressionMail: GmailSyncReading, GmailMutating, GmailSearching {
    static let accountID = "selection-regression"
    private var mail: [String: GmailConversation]
    private var version = 100
    private var changes: [(version: Int, id: String)] = []
    private var arrivals = 0
    var rejectNextRemoval = false

    init(empty: Bool = false) {
        let initial = empty ? [] : [
            Self.thread("open", subject: "Thread to open", order: 2),
            Self.thread("older", subject: "Next older thread", order: 1)
        ]
        mail = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
    }

    func makeHub() async throws -> MailHub {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: Self.accountID, email: MailStore.accountEmail))
        let inbox = try await mailbox(.inbox, pageToken: nil)
        try await session.applySync(GmailSyncBatch(snapshots: [.inbox: inbox], expectedHistoryID: nil, historyID: String(version)))
        let account = StoredAccount(
            identity: GoogleIdentity(id: Self.accountID, email: MailStore.accountEmail, name: MailStore.accountName),
            credentials: GoogleCredentials(refreshToken: "", accessToken: "", expiresAt: .distantFuture,
                                           scopes: Set(GoogleOAuthClient.requiredScopes)),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let accounts = AccountStore(vault: MemoryAccountVault([account]))
        accounts.restore()
        let hub = MailHub(accounts: accounts, syncsInBackground: false, cache: cache) { _ in self }
        await hub.prepare()
        await hub.reconcile()
        return hub
    }

    func insertNewerMail() {
        arrivals += 1
        let id = "arrival-\(arrivals)"
        mail[id] = Self.thread(id, subject: "Newer arrival \(arrivals)", order: arrivals + 2)
        record(id)
    }

    @MainActor func currentHistoryID() async throws -> String { String(version) }

    @MainActor func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        let since = Int(startHistoryID) ?? 0
        return GmailHistoryPage(history: changes.filter { $0.version > since }.map {
            GmailHistoryPage.Record(id: String($0.version), messages: [.init(id: "message-" + $0.id, threadId: $0.id)],
                                    messagesAdded: nil, messagesDeleted: nil, labelsAdded: nil, labelsRemoved: nil)
        }, nextPageToken: nil, historyId: String(version))
    }

    @MainActor func metadata(id: String) async throws -> GmailConversation? {
        mail[id].map { conversation in
            GmailConversation(id: conversation.id, subject: conversation.subject, messages: conversation.messages.map {
                var message = $0
                message.bodyLoaded = false
                return message
            })
        }
    }

    @MainActor func conversation(id: String) async throws -> GmailConversation {
        guard let conversation = mail[id] else { throw GmailError.http(404) }
        return conversation
    }

    @MainActor func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        let conversations = mail.values.filter { conversation in
            let labels = conversation.labelIDs
            switch mailbox {
            case .inbox: return labels.contains("INBOX") && !labels.contains("TRASH")
            case .archive: return !labels.contains("INBOX") && !labels.contains("TRASH")
            case .trash: return labels.contains("TRASH")
            default: return false
            }
        }.sorted { $0.latestDate > $1.latestDate }
        return GmailPage(conversations: conversations, nextPageToken: nil)
    }

    @MainActor func search(_ query: String, in folder: Mailbox?, pageToken: String?) async throws -> GmailPage {
        let source: [GmailConversation]
        if let folder { source = try await mailbox(folder, pageToken: nil).conversations }
        else { source = Array(mail.values) }
        // This fixture only needs literal search, not Gmail's operator grammar.
        let conversations = source.filter { $0.matches(query) }.sorted { $0.latestDate > $1.latestDate }
        return GmailPage(conversations: conversations, nextPageToken: nil)
    }

    @MainActor func unreadInboxCount() async throws -> Int { 0 }

    @MainActor func archive(threadID: String) async throws {
        try checkRemoval()
        mail[threadID] = mail[threadID]?.setting("INBOX", to: false)
        record(threadID)
    }

    @MainActor func trash(threadID: String) async throws {
        try checkRemoval()
        mail[threadID] = mail[threadID]?.setting("INBOX", to: false).setting("TRASH", to: true)
        record(threadID)
    }

    @MainActor func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        mail[threadID] = mail[threadID]?.setting(label, to: on)
        record(threadID)
    }

    private func checkRemoval() throws {
        if rejectNextRemoval {
            rejectNextRemoval = false
            throw GmailError.http(403)
        }
    }

    private func record(_ id: String) {
        version += 1
        changes.append((version, id))
    }

    private static func thread(_ id: String, subject: String, order: Int) -> GmailConversation {
        GmailConversation(id: id, subject: subject, messages: [
            GmailMessage(id: "message-" + id, senderName: "Sample Sender", senderEmail: "sender@example.com",
                         recipient: MailStore.accountEmail, cc: "", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(order * 60)),
                         snippet: "Selection regression sample", body: "\(subject)\n\nWatch the list highlight, detail pane and keyboard navigation while inserting and archiving mail.",
                         labelIDs: ["INBOX"])
        ])
    }
}
