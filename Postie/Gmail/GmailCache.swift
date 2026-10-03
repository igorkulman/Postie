import Foundation
import GRDB

nonisolated struct CachedGmailAccount: Equatable, Sendable {
    let id: String
    let email: String
}

nonisolated struct CachedGmailMailbox: Sendable {
    let conversations: [GmailConversation]
    let nextPageToken: String?
    let fetchedAt: Date
}

nonisolated enum GmailCacheError: Error, Equatable {
    case sessionExpired
    case checkpointChanged
}

nonisolated struct GmailCacheCheckpoint: Sendable {
    let historyID: String?
}

// A lease makes revocation effective at the database boundary, not just in the UI.
// Every read/write checks it on the actor that submits operations to GRDB's serial
// writer. Revocation queues account deletion after earlier submitted writes; later
// writes are rejected. Reads also recheck after awaiting database access.
nonisolated struct GmailCacheSession: Sendable {
    fileprivate let cache: GmailCache
    fileprivate let accountID: String
    fileprivate let lease: UUID

    func loadMailbox(_ mailbox: Mailbox) async throws -> CachedGmailMailbox? {
        try await cache.loadMailbox(mailbox, session: self)
    }
    func savePage(_ page: GmailPage, mailbox: Mailbox, refreshing: Bool, checkpoint: GmailCacheCheckpoint? = nil) async throws -> CachedGmailMailbox {
        try await cache.savePage(page, mailbox: mailbox, refreshing: refreshing, checkpoint: checkpoint, session: self)
    }
    func conversation(id: String) async throws -> GmailConversation? {
        try await cache.conversation(id: id, session: self)
    }
    func saveConversation(_ conversation: GmailConversation, checkpoint: GmailCacheCheckpoint? = nil) async throws {
        try await cache.saveConversation(conversation, checkpoint: checkpoint, session: self)
    }
    func historyID() async throws -> String? { try await cache.historyID(session: self) }
    func checkpoint() async throws -> GmailCacheCheckpoint { GmailCacheCheckpoint(historyID: try await historyID()) }
    func cachedMailboxes() async throws -> [Mailbox] { try await cache.cachedMailboxes(session: self) }
    func cachedThreadIDs() async throws -> [String] { try await cache.cachedThreadIDs(session: self) }
    func applySync(_ batch: GmailSyncBatch) async throws { try await cache.applySync(batch, session: self) }
    func unreadCount() async throws -> Int? { try await cache.unreadCount(session: self) }
    func saveUnreadCount(_ count: Int) async throws { try await cache.saveUnreadCount(count, session: self) }
    /// Cached messages whose address headers mention `query`, newest first.
    func contactSources(matching query: String, limit: Int = 2000) async throws -> [ContactSource] {
        try await cache.contactSources(matching: query, limit: limit, session: self)
    }
    /// Replaces the account's Google contacts with a fresh copy.
    func saveContacts(_ contacts: [DirectoryContact]) async throws { try await cache.saveContacts(contacts, session: self) }
    func contacts(matching query: String, limit: Int = 500) async throws -> [DirectoryContact] {
        try await cache.contacts(matching: query, limit: limit, session: self)
    }
    func invalidate() async { await cache.invalidate(self) }
}

actor GmailCache {
    private let database: DatabaseQueue
    private var leases: [String: UUID] = [:]

    // Initialization, migrations, and synchronous SQLite work stay off the main actor.
    @concurrent
    static func open(at url: URL? = nil) async throws -> GmailCache {
        let fileManager = FileManager.default
        let path = try url ?? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("Postie", isDirectory: true).appendingPathComponent("mail.sqlite")
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        let cache = try GmailCache(database: DatabaseQueue(path: path.path, configuration: configuration))
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return cache
    }

    @concurrent
    static func inMemory() async throws -> GmailCache {
        try GmailCache(database: DatabaseQueue())
    }

    private init(database: DatabaseQueue) throws {
        self.database = database
        var migrator = DatabaseMigrator()
        migrator.registerMigration("mail-cache-v1") { db in
            try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL, email TEXT NOT NULL, lastUsed REAL NOT NULL,
                unreadCount INTEGER, historyID TEXT
            );
            CREATE TABLE threads (
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                id TEXT NOT NULL, subject TEXT NOT NULL, PRIMARY KEY (accountID, id)
            );
            CREATE TABLE messages (
                accountID TEXT NOT NULL, id TEXT NOT NULL, threadID TEXT NOT NULL,
                senderName TEXT NOT NULL, senderEmail TEXT NOT NULL, recipient TEXT NOT NULL,
                cc TEXT NOT NULL, replyTo TEXT NOT NULL DEFAULT '', date REAL NOT NULL, snippet TEXT NOT NULL,
                body TEXT, htmlBody TEXT, bodyLoaded BOOLEAN NOT NULL DEFAULT 0,
                PRIMARY KEY (accountID, id),
                FOREIGN KEY (accountID, threadID) REFERENCES threads(accountID, id) ON DELETE CASCADE
            );
            CREATE INDEX messages_thread ON messages(accountID, threadID, date);
            CREATE TABLE attachments (
                accountID TEXT NOT NULL, messageID TEXT NOT NULL, partID TEXT NOT NULL,
                attachmentID TEXT NOT NULL, filename TEXT NOT NULL, mimeType TEXT NOT NULL,
                size INTEGER NOT NULL, position INTEGER NOT NULL,
                PRIMARY KEY (accountID, messageID, partID),
                FOREIGN KEY (accountID, messageID) REFERENCES messages(accountID, id) ON DELETE CASCADE
            );
            CREATE TABLE messageLabels (
                accountID TEXT NOT NULL, messageID TEXT NOT NULL, labelID TEXT NOT NULL,
                PRIMARY KEY (accountID, messageID, labelID),
                FOREIGN KEY (accountID, messageID) REFERENCES messages(accountID, id) ON DELETE CASCADE
            );
            CREATE INDEX labels_lookup ON messageLabels(accountID, labelID);
            CREATE TABLE folderEntries (
                accountID TEXT NOT NULL, mailbox TEXT NOT NULL, threadID TEXT NOT NULL, position INTEGER NOT NULL,
                PRIMARY KEY (accountID, mailbox, threadID),
                FOREIGN KEY (accountID, threadID) REFERENCES threads(accountID, id) ON DELETE CASCADE
            );
            CREATE TABLE folderState (
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                mailbox TEXT NOT NULL, nextPageToken TEXT, fetchedAt REAL NOT NULL,
                PRIMARY KEY (accountID, mailbox)
            );
            """)
        }
        migrator.registerMigration("contacts-v2") { db in
            try db.execute(sql: """
            CREATE TABLE contacts (
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                email TEXT NOT NULL, name TEXT NOT NULL, saved BOOLEAN NOT NULL,
                PRIMARY KEY (accountID, email)
            );
            """)
        }
        try migrator.migrate(database)
    }

    func session(for account: CachedGmailAccount) async throws -> GmailCacheSession {
        try Task.checkCancellation()
        let lease = UUID()
        leases[account.id] = lease
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO accounts(id, email, lastUsed) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET email = excluded.email, lastUsed = excluded.lastUsed
                """, arguments: [account.id, account.email, Date().timeIntervalSince1970])
        }
        let session = GmailCacheSession(cache: self, accountID: account.id, lease: lease)
        try check(session)
        return session
    }

    func removeAccount(id: String) async throws {
        // Invalidate even if deletion fails: old network requests must never write again.
        leases[id] = nil
        try await database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id])
        }
    }

    fileprivate func invalidate(_ session: GmailCacheSession) {
        if leases[session.accountID] == session.lease { leases[session.accountID] = nil }
    }

    private func check(_ session: GmailCacheSession) throws {
        try Task.checkCancellation()
        guard leases[session.accountID] == session.lease else { throw GmailCacheError.sessionExpired }
    }

    fileprivate func loadMailbox(_ mailbox: Mailbox, session: GmailCacheSession) async throws -> CachedGmailMailbox? {
        try check(session)
        let saved = try await database.read { try Self.mailbox($0, accountID: session.accountID, mailbox: mailbox) }
        try check(session)
        return saved
    }

    fileprivate func savePage(_ page: GmailPage, mailbox: Mailbox, refreshing: Bool,
                              checkpoint: GmailCacheCheckpoint?, session: GmailCacheSession) async throws -> CachedGmailMailbox {
        try check(session)
        let saved = try await database.write { db in
            let accountID = session.accountID
            if let checkpoint { try Self.checkCheckpoint(db, accountID: accountID, expected: checkpoint.historyID) }
            if refreshing {
                // This is a folder page snapshot, not evidence of deletion from the account.
                try db.execute(sql: "DELETE FROM folderEntries WHERE accountID = ? AND mailbox = ?",
                               arguments: [accountID, mailbox.rawValue])
            }
            var position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM folderEntries WHERE accountID = ? AND mailbox = ?",
                                            arguments: [accountID, mailbox.rawValue])! + 1
            for conversation in page.conversations {
                try Task.checkCancellation()
                try Self.upsert(conversation, accountID: accountID, db: db)
                try db.execute(sql: "INSERT OR IGNORE INTO folderEntries(accountID, mailbox, threadID, position) VALUES (?, ?, ?, ?)",
                               arguments: [accountID, mailbox.rawValue, conversation.id, position])
                position += 1
            }
            try db.execute(sql: """
                INSERT INTO folderState(accountID, mailbox, nextPageToken, fetchedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(accountID, mailbox) DO UPDATE SET nextPageToken = excluded.nextPageToken, fetchedAt = excluded.fetchedAt
                """, arguments: [accountID, mailbox.rawValue, page.nextPageToken, Date().timeIntervalSince1970])
            try Task.checkCancellation()
            return try Self.mailbox(db, accountID: accountID, mailbox: mailbox)!
        }
        try check(session)
        return saved
    }

    fileprivate func conversation(id: String, session: GmailCacheSession) async throws -> GmailConversation? {
        try check(session)
        let saved = try await database.read { try Self.conversation($0, accountID: session.accountID, id: id) }
        try check(session)
        return saved
    }

    fileprivate func saveConversation(_ conversation: GmailConversation, checkpoint: GmailCacheCheckpoint?, session: GmailCacheSession) async throws {
        try check(session)
        try await database.write { db in
            if let checkpoint { try Self.checkCheckpoint(db, accountID: session.accountID, expected: checkpoint.historyID) }
            try Self.upsert(conversation, accountID: session.accountID, db: db)
            try Task.checkCancellation()
        }
        try check(session)
    }

    fileprivate func contactSources(matching query: String, limit: Int, session: GmailCacheSession) async throws -> [ContactSource] {
        try check(session)
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%" + escaped + "%"
        let sources = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT senderName, senderEmail, recipient, cc, date FROM messages
                WHERE accountID = ?1 AND (senderName LIKE ?2 ESCAPE '\\' OR senderEmail LIKE ?2 ESCAPE '\\'
                    OR recipient LIKE ?2 ESCAPE '\\' OR cc LIKE ?2 ESCAPE '\\')
                ORDER BY date DESC LIMIT ?3
                """, arguments: [session.accountID, pattern, limit]).map {
                ContactSource(senderName: $0["senderName"], senderEmail: $0["senderEmail"], recipient: $0["recipient"],
                              cc: $0["cc"], date: Date(timeIntervalSince1970: $0["date"]))
            }
        }
        try check(session)
        return sources
    }

    fileprivate func saveContacts(_ contacts: [DirectoryContact], session: GmailCacheSession) async throws {
        try check(session)
        try await database.write { db in
            try db.execute(sql: "DELETE FROM contacts WHERE accountID = ?", arguments: [session.accountID])
            for contact in contacts {
                // A saved contact wins over the same address among the collected ones.
                try db.execute(sql: """
                    INSERT INTO contacts (accountID, email, name, saved) VALUES (?1, ?2, ?3, ?4)
                    ON CONFLICT(accountID, email) DO UPDATE SET
                        name = CASE WHEN excluded.saved >= saved THEN excluded.name ELSE name END,
                        saved = MAX(saved, excluded.saved)
                    """, arguments: [session.accountID, contact.email.lowercased(), contact.name, contact.isSaved])
            }
            try Task.checkCancellation()
        }
        try check(session)
    }

    fileprivate func contacts(matching query: String, limit: Int, session: GmailCacheSession) async throws -> [DirectoryContact] {
        try check(session)
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%" + escaped + "%"
        let found = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name, email, saved FROM contacts
                WHERE accountID = ?1 AND (name LIKE ?2 ESCAPE '\\' OR email LIKE ?2 ESCAPE '\\') LIMIT ?3
                """, arguments: [session.accountID, pattern, limit]).map {
                DirectoryContact(name: $0["name"], email: $0["email"], isSaved: $0["saved"])
            }
        }
        try check(session)
        return found
    }

    fileprivate func unreadCount(session: GmailCacheSession) async throws -> Int? {
        try check(session)
        let count = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT unreadCount FROM accounts WHERE id = ?", arguments: [session.accountID])
        }
        try check(session)
        return count
    }

    fileprivate func saveUnreadCount(_ count: Int, session: GmailCacheSession) async throws {
        try check(session)
        try await database.write { db in
            try db.execute(sql: "UPDATE accounts SET unreadCount = ? WHERE id = ?", arguments: [count, session.accountID])
        }
        try check(session)
    }

    fileprivate func historyID(session: GmailCacheSession) async throws -> String? {
        try check(session)
        let value = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT historyID FROM accounts WHERE id = ?", arguments: [session.accountID])
        }
        try check(session)
        return value
    }

    fileprivate func cachedMailboxes(session: GmailCacheSession) async throws -> [Mailbox] {
        try check(session)
        let values = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT mailbox FROM folderState WHERE accountID = ?", arguments: [session.accountID])
        }
        try check(session)
        return values.compactMap(Mailbox.init(rawValue:)).filter { $0 != .outbox }
    }

    fileprivate func cachedThreadIDs(session: GmailCacheSession) async throws -> [String] {
        try check(session)
        let values = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM threads WHERE accountID = ?", arguments: [session.accountID])
        }
        try check(session)
        return values
    }

    fileprivate func applySync(_ batch: GmailSyncBatch, session: GmailCacheSession) async throws {
        try check(session)
        try await database.write { db in
            let accountID = session.accountID
            try Self.checkCheckpoint(db, accountID: accountID, expected: batch.expectedHistoryID)
            guard GmailHistoryPage.validID(batch.historyID) else { throw GmailError.invalidResponse }
            var affected = Set(batch.conversations.map(\.id))
            for (folder, page) in batch.snapshots {
                try db.execute(sql: "DELETE FROM folderEntries WHERE accountID = ? AND mailbox = ?", arguments: [accountID, folder.rawValue])
                for conversation in page.conversations {
                    try Self.upsert(conversation, accountID: accountID, db: db)
                    affected.insert(conversation.id)
                }
                try db.execute(sql: """
                    INSERT INTO folderState(accountID, mailbox, nextPageToken, fetchedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(accountID, mailbox) DO UPDATE SET nextPageToken = excluded.nextPageToken, fetchedAt = excluded.fetchedAt
                    """, arguments: [accountID, folder.rawValue, page.nextPageToken, Date().timeIntervalSince1970])
            }
            let folders = try String.fetchAll(db, sql: "SELECT mailbox FROM folderState WHERE accountID = ?", arguments: [accountID])
                .compactMap(Mailbox.init(rawValue:)).filter { $0 != .outbox }
            for conversation in batch.conversations {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM threads WHERE accountID = ? AND id = ?)",
                                              arguments: [accountID, conversation.id])!
                // Stay a partial cache: don't store unrelated folders' mail.
                if exists || folders.contains(where: { conversation.belongs(to: $0) }) {
                    try Self.upsert(conversation, accountID: accountID, db: db)
                }
            }
            for id in batch.deletedThreadIDs {
                try db.execute(sql: "DELETE FROM threads WHERE accountID = ? AND id = ?", arguments: [accountID, id])
            }
            for id in affected.subtracting(batch.deletedThreadIDs) {
                guard let conversation = try Self.conversation(db, accountID: accountID, id: id) else { continue }
                try db.execute(sql: "DELETE FROM folderEntries WHERE accountID = ? AND threadID = ?", arguments: [accountID, id])
                for folder in folders where conversation.belongs(to: folder) {
                    try db.execute(sql: "INSERT INTO folderEntries(accountID, mailbox, threadID, position) VALUES (?, ?, ?, 0)",
                                   arguments: [accountID, folder.rawValue, id])
                }
            }
            // History can add/move a thread or append a reply. Reorder loaded rows,
            // retaining downloaded older pages and their bodies.
            for folder in folders {
                let ids = try String.fetchAll(db, sql: """
                    SELECT e.threadID FROM folderEntries e JOIN messages m ON m.accountID = e.accountID AND m.threadID = e.threadID
                    WHERE e.accountID = ? AND e.mailbox = ? GROUP BY e.threadID ORDER BY MAX(m.date) DESC, e.threadID
                    """, arguments: [accountID, folder.rawValue])
                for (position, id) in ids.enumerated() {
                    try db.execute(sql: "UPDATE folderEntries SET position = ? WHERE accountID = ? AND mailbox = ? AND threadID = ?",
                                   arguments: [position, accountID, folder.rawValue, id])
                }
            }
            try db.execute(sql: "UPDATE folderState SET fetchedAt = ? WHERE accountID = ?", arguments: [Date().timeIntervalSince1970, accountID])
            // The checkpoint and every mail/label/folder change commit together.
            try db.execute(sql: "UPDATE accounts SET historyID = ? WHERE id = ?", arguments: [batch.historyID, accountID])
        }
        try check(session)
    }

    nonisolated private static func checkCheckpoint(_ db: Database, accountID: String, expected: String?) throws {
        let current = try String.fetchOne(db, sql: "SELECT historyID FROM accounts WHERE id = ?", arguments: [accountID])
        guard current == expected else { throw GmailCacheError.checkpointChanged }
    }

    nonisolated private static func mailbox(_ db: Database, accountID: String, mailbox: Mailbox) throws -> CachedGmailMailbox? {
        guard let state = try Row.fetchOne(db, sql: "SELECT nextPageToken, fetchedAt FROM folderState WHERE accountID = ? AND mailbox = ?",
                                          arguments: [accountID, mailbox.rawValue]) else { return nil }
        let ids = try String.fetchAll(db, sql: "SELECT threadID FROM folderEntries WHERE accountID = ? AND mailbox = ? ORDER BY position",
                                      arguments: [accountID, mailbox.rawValue])
        return CachedGmailMailbox(conversations: try ids.compactMap { try conversation(db, accountID: accountID, id: $0) },
                                  nextPageToken: state["nextPageToken"], fetchedAt: Date(timeIntervalSince1970: state["fetchedAt"]))
    }

    nonisolated private static func conversation(_ db: Database, accountID: String, id: String) throws -> GmailConversation? {
        guard let subject = try String.fetchOne(db, sql: "SELECT subject FROM threads WHERE accountID = ? AND id = ?",
                                                arguments: [accountID, id]) else { return nil }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM messages WHERE accountID = ? AND threadID = ? ORDER BY date, id",
                                   arguments: [accountID, id])
        let messages = try rows.map { row -> GmailMessage in
            let messageID: String = row["id"]
            let labels = try String.fetchAll(db, sql: "SELECT labelID FROM messageLabels WHERE accountID = ? AND messageID = ?",
                                             arguments: [accountID, messageID])
            let attachments = try Row.fetchAll(db, sql: """
                SELECT * FROM attachments WHERE accountID = ? AND messageID = ? ORDER BY position
                """, arguments: [accountID, messageID]).map { row in
                MailAttachment(messageID: messageID, partID: row["partID"], attachmentID: row["attachmentID"],
                               filename: row["filename"], mimeType: row["mimeType"], size: row["size"])
            }
            return GmailMessage(id: messageID, senderName: row["senderName"], senderEmail: row["senderEmail"],
                                recipient: row["recipient"], cc: row["cc"], date: Date(timeIntervalSince1970: row["date"]),
                                snippet: row["snippet"], body: (row["body"] as String?) ?? "", bodyLoaded: row["bodyLoaded"],
                                htmlBody: row["htmlBody"], attachments: attachments, replyTo: row["replyTo"],
                                labelIDs: Set(labels))
        }
        return GmailConversation(id: id, subject: subject, messages: messages)
    }

    nonisolated private static func upsert(_ conversation: GmailConversation, accountID: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO threads(accountID, id, subject) VALUES (?, ?, ?)
            ON CONFLICT(accountID, id) DO UPDATE SET subject = excluded.subject
            """, arguments: [accountID, conversation.id, conversation.subject])
        let existing = try String.fetchAll(db, sql: "SELECT id FROM messages WHERE accountID = ? AND threadID = ?",
                                           arguments: [accountID, conversation.id])
        let incoming = Set(conversation.messages.map(\.id))
        for id in existing where !incoming.contains(id) {
            try db.execute(sql: "DELETE FROM messages WHERE accountID = ? AND id = ?", arguments: [accountID, id])
        }
        for message in conversation.messages {
            // Received message bodies are immutable; drafts may change in place.
            let keepBody = !message.bodyLoaded && !message.labelIDs.contains("DRAFT")
            try db.execute(sql: """
                INSERT INTO messages(accountID, id, threadID, senderName, senderEmail, recipient, cc, date, snippet, body, htmlBody, bodyLoaded, replyTo)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(accountID, id) DO UPDATE SET
                    threadID = excluded.threadID, senderName = excluded.senderName, senderEmail = excluded.senderEmail,
                    recipient = excluded.recipient, cc = excluded.cc, replyTo = excluded.replyTo, date = excluded.date, snippet = excluded.snippet,
                    body = CASE WHEN ? THEN messages.body ELSE excluded.body END,
                    htmlBody = CASE WHEN ? THEN messages.htmlBody ELSE excluded.htmlBody END,
                    bodyLoaded = CASE WHEN ? THEN messages.bodyLoaded ELSE excluded.bodyLoaded END
                """, arguments: [accountID, message.id, conversation.id, message.senderName, message.senderEmail,
                                 message.recipient, message.cc, message.date.timeIntervalSince1970, message.snippet,
                                 message.bodyLoaded ? message.body : nil, message.htmlBody, message.bodyLoaded,
                                 message.replyTo, keepBody, keepBody, keepBody])
            try db.execute(sql: "DELETE FROM attachments WHERE accountID = ? AND messageID = ?", arguments: [accountID, message.id])
            for (position, attachment) in message.attachments.enumerated() {
                try db.execute(sql: """
                    INSERT INTO attachments(accountID, messageID, partID, attachmentID, filename, mimeType, size, position)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [accountID, message.id, attachment.partID, attachment.attachmentID, attachment.filename,
                                     attachment.mimeType, attachment.size, position])
            }
            try db.execute(sql: "DELETE FROM messageLabels WHERE accountID = ? AND messageID = ?", arguments: [accountID, message.id])
            for label in message.labelIDs {
                try db.execute(sql: "INSERT INTO messageLabels(accountID, messageID, labelID) VALUES (?, ?, ?)",
                               arguments: [accountID, message.id, label])
            }
        }
    }
}
