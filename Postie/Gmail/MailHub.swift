import Foundation
import Observation

/// A Gmail thread ID is only unique within one account, so merged lists identify conversations by both.
nonisolated struct ConversationKey: Hashable, Sendable {
    let accountID: String
    let threadID: String
}

struct MergedConversation: Identifiable, Equatable {
    let key: ConversationKey
    let conversation: GmailConversation
    var id: ConversationKey { key }
}

/// An account that can send mail, as offered in the composer's From picker.
struct SendingAccount: Identifiable, Hashable {
    let id: String
    let email: String
}

/// Something worth telling the person about, possibly with a way to fix it.
struct HubNotice: Identifiable, Equatable {
    enum Fix: Equatable { case reconnect(accountID: String), retry }
    let id: String
    let message: String
    var isError = false
    var fix: Fix?
}

/// One connected account: its reader, its cache and its own background sync.
@MainActor
final class AccountSession: Identifiable {
    let identity: GoogleIdentity
    let reader: GmailReaderStore
    private var syncTask: Task<Void, Never>?

    var id: String { identity.id }
    var email: String { identity.email }

    init(identity: GoogleIdentity, reader: GmailReaderStore) {
        self.identity = identity
        self.reader = reader
    }

    /// Refreshes now and then once a minute, for as long as the session lives.
    func startSyncing(interval: Duration = .seconds(60)) {
        guard syncTask == nil else { return }
        let reader = reader
        syncTask = Task {
            await reader.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await reader.refresh()
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        reader.reset()
    }
}

/// Every connected account's mail, merged into the single set of folders the person sees.
/// Each conversation stays tied to its account, so actions and replies go to the right one.
@MainActor
@Observable
final class MailHub {
    let accounts: AccountStore
    private(set) var sessions: [AccountSession] = []
    private(set) var mailbox: Mailbox = .inbox
    private(set) var isPreparing: Bool
    private(set) var storageError: String?

    @ObservationIgnored private var cache: GmailCache?
    @ObservationIgnored private let persistsMail: Bool
    @ObservationIgnored private let syncsInBackground: Bool
    @ObservationIgnored private let makeAPI: (@MainActor (String) -> any GmailReading)?

    /// `makeAPI` lets previews and tests supply canned mail instead of talking to Gmail.
    init(accounts: AccountStore, persistsMail: Bool = true, syncsInBackground: Bool = true,
         makeAPI: (@MainActor (String) -> any GmailReading)? = nil) {
        self.accounts = accounts
        self.persistsMail = persistsMail
        self.syncsInBackground = syncsInBackground
        self.makeAPI = makeAPI
        isPreparing = persistsMail
    }

    // MARK: Lifecycle

    func prepare() async {
        defer { isPreparing = false }
        guard persistsMail else { return }
        do {
            cache = try await GmailCache.open()
        } catch {
            storageError = String(localized: "Unable to open saved mail. You can connect Gmail, but new mail may not be saved locally.")
        }
    }

    /// Makes the sessions match the connected accounts. Cheap to call whenever the accounts change.
    func reconcile() async {
        let connected = accounts.accounts
        for session in sessions where !connected.contains(where: { $0.id == session.id }) {
            session.stop()
        }
        sessions.removeAll { session in !connected.contains { $0.id == session.id } }
        for entry in connected where !sessions.contains(where: { $0.id == entry.id }) {
            guard let session = await makeSession(for: entry.identity) else { continue }
            guard !Task.isCancelled, accounts.accounts.contains(where: { $0.id == entry.id }),
                  !sessions.contains(where: { $0.id == entry.id }) else { session.stop(); continue }
            sessions.append(session)
            if syncsInBackground, persistsMail { session.startSyncing() }
        }
        // Keep the order the accounts were added in, however long each took to open.
        let order = connected.map(\.id)
        sessions.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }

    private func makeSession(for identity: GoogleIdentity) async -> AccountSession? {
        let accounts = accounts
        let id = identity.id
        let api = makeAPI?(id) ?? GmailAPI { try await accounts.accessToken(for: id) }
        var savedSession: GmailCacheSession?
        if let cache {
            do { savedSession = try await cache.session(for: CachedGmailAccount(id: id, email: identity.email)) }
            catch is CancellationError { return nil }
            catch {
                storageError = String(localized: "Unable to open the account cache. This session will use online mail only.")
            }
        }
        let reader = GmailReaderStore(api: api, mailbox: mailbox, cache: savedSession)
        await reader.restoreCachedMailbox()
        return AccountSession(identity: identity, reader: reader)
    }

    /// Deletes the account's downloaded mail, then forgets the account. Does nothing if the mail cannot be removed.
    func removeAccount(_ id: String) async {
        do { try await cache?.removeAccount(id: id) }
        catch {
            // Do not claim a successful removal while leaving an offline copy of the mail behind.
            accounts.error = String(localized: "Unable to remove locally cached mail. The account was not removed.")
            return
        }
        sessions.first { $0.id == id }?.stop()
        sessions.removeAll { $0.id == id }
        accounts.remove(id)
    }

    // MARK: Folders

    func changeMailbox(_ mailbox: Mailbox) {
        guard self.mailbox != mailbox else { return }
        self.mailbox = mailbox
        for session in sessions { session.reader.changeMailbox(mailbox) }
    }

    /// Shows what is saved for the current folder, then asks Gmail for anything new, for every account at once.
    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                let reader = session.reader
                group.addTask { @MainActor in
                    await reader.restoreCachedMailbox()
                    await reader.refresh()
                }
            }
        }
    }

    func restoreCachedMailbox() async {
        for session in sessions { await session.reader.restoreCachedMailbox() }
    }

    func loadMore() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions where session.reader.nextPageToken != nil {
                let reader = session.reader
                group.addTask { @MainActor in await reader.loadMore() }
            }
        }
    }

    // MARK: Merged state

    /// The folder's conversations from every account, newest first.
    var conversations: [MergedConversation] {
        sessions.flatMap { session in
            session.reader.conversations.map {
                MergedConversation(key: ConversationKey(accountID: session.id, threadID: $0.id), conversation: $0)
            }
        }
        .sorted { $0.conversation.latestDate > $1.conversation.latestDate }
    }

    var unreadInboxCount: Int? {
        let counts = sessions.compactMap(\.reader.unreadInboxCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    var isLoadingMailbox: Bool { sessions.contains { $0.reader.isLoadingMailbox } }
    var isRestoringCache: Bool { sessions.contains { $0.reader.isRestoringCache } }
    var showingCachedMail: Bool { sessions.contains { $0.reader.showingCachedMail } }
    var hasMorePages: Bool { sessions.contains { $0.reader.nextPageToken != nil } }
    var lastRefreshed: Date? { sessions.compactMap(\.reader.lastRefreshed).min() }
    var mailboxVersion: Int { sessions.reduce(0) { $0 + $1.reader.mailboxVersion } }
    var loadedCount: Int { sessions.reduce(0) { $0 + $1.reader.conversations.count } }
    var hasMultipleAccounts: Bool { sessions.count > 1 }

    var sendingAccounts: [SendingAccount] {
        sessions.filter { $0.reader.canSend && !isDisconnected($0.id) }.map { SendingAccount(id: $0.id, email: $0.email) }
    }

    /// Where new messages come from unless the person picks another account.
    var defaultSendingAccount: SendingAccount? {
        let candidates = sendingAccounts
        return candidates.first { $0.id == accounts.defaultAccount?.id } ?? candidates.first
    }

    func email(for accountID: String) -> String? { session(for: accountID)?.email }

    private func isDisconnected(_ id: String) -> Bool {
        accounts.accounts.first { $0.id == id }?.needsReconnect ?? true
    }

    /// Problems to show above the list, each labelled with its account once there is more than one.
    var notices: [HubNotice] {
        var notices: [HubNotice] = []
        if let storageError { notices.append(HubNotice(id: "storage", message: storageError)) }
        for session in sessions {
            let label: (String) -> String = { self.hasMultipleAccounts ? "\(session.email): \($0)" : $0 }
            if isDisconnected(session.id) {
                notices.append(HubNotice(
                    id: "reconnect-\(session.id)",
                    message: String(localized: "Postie can no longer sync \(session.email). Sign in again to update it; downloaded messages can still be read."),
                    fix: accounts.configurationIssue == nil ? .reconnect(accountID: session.id) : nil
                ))
            }
            if let cacheError = session.reader.cacheError {
                notices.append(HubNotice(id: "cache-\(session.id)", message: label(cacheError)))
            }
            if let error = session.reader.mailboxError, !isDisconnected(session.id) {
                notices.append(HubNotice(id: "error-\(session.id)", message: label(error), isError: true, fix: .retry))
            }
        }
        return notices
    }

    // MARK: One conversation

    private func session(for accountID: String) -> AccountSession? {
        sessions.first { $0.id == accountID }
    }

    func conversation(for key: ConversationKey) -> GmailConversation? {
        session(for: key.accountID)?.reader.conversations.first { $0.id == key.threadID }
    }

    /// The fully loaded conversation, once its owner has opened it.
    func openConversation(for key: ConversationKey?) -> GmailConversation? {
        guard let key, let selected = session(for: key.accountID)?.reader.selectedConversation,
              selected.id == key.threadID else { return nil }
        return selected
    }

    func isLoadingConversation(_ key: ConversationKey?) -> Bool {
        key.flatMap { session(for: $0.accountID)?.reader.isLoadingConversation } ?? false
    }

    func conversationError(_ key: ConversationKey?) -> String? {
        key.flatMap { session(for: $0.accountID)?.reader.conversationError }
    }

    func canModifyLabels(_ key: ConversationKey?) -> Bool {
        key.flatMap { session(for: $0.accountID)?.reader.canModifyLabels } ?? false
    }

    func canArchive(_ key: ConversationKey?) -> Bool {
        key.flatMap { session(for: $0.accountID)?.reader.canArchive } ?? false
    }

    func canTrash(_ key: ConversationKey?) -> Bool {
        key.flatMap { session(for: $0.accountID)?.reader.canTrash } ?? false
    }

    /// Opens a conversation in its account and closes whatever another account had open.
    func select(_ key: ConversationKey?) async {
        for session in sessions where session.id != key?.accountID { await session.reader.select(nil) }
        guard let key, let session = session(for: key.accountID) else { return }
        await session.reader.select(key.threadID)
    }

    @discardableResult
    func archive(_ key: ConversationKey) async -> Bool {
        await session(for: key.accountID)?.reader.archive(key.threadID) ?? false
    }

    @discardableResult
    func trash(_ key: ConversationKey) async -> Bool {
        await session(for: key.accountID)?.reader.trash(key.threadID) ?? false
    }

    func setUnread(_ key: ConversationKey, _ unread: Bool) async {
        await session(for: key.accountID)?.reader.setUnread(key.threadID, unread)
    }

    func setStarred(_ key: ConversationKey, _ starred: Bool) async {
        await session(for: key.accountID)?.reader.setStarred(key.threadID, starred)
    }

    /// Sends from the draft's account. A reply always goes out from the account that received the mail.
    func send(_ draft: ComposeDraft) async throws {
        guard let id = draft.accountID ?? defaultSendingAccount?.id, let session = session(for: id) else {
            throw GmailError.signInRequired
        }
        try await session.reader.send(OutgoingMessage(
            from: session.email,
            to: draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            cc: draft.cc.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: draft.subject, body: draft.body, threadID: draft.gmailThreadID
        ))
    }
}
