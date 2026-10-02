import Foundation
import Observation
import SwiftUI
import os

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

/// The conversations the list shows, with the lookups the UI needs done once instead of on every read.
struct MergedList {
    let conversations: [MergedConversation]
    let keys: [ConversationKey]
    private let byKey: [ConversationKey: MergedConversation]

    init(_ conversations: [MergedConversation] = []) {
        self.conversations = conversations
        keys = conversations.map(\.key)
        byKey = Dictionary(conversations.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    subscript(key: ConversationKey) -> MergedConversation? { byKey[key] }
}

/// Where a search looks.
enum SearchScope: Hashable {
    case folder, allMail
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
                // After a failure (often Gmail rate limiting) give it room instead of asking again at once.
                do { try await Task.sleep(for: reader.mailboxError == nil ? interval : interval * 5) } catch { return }
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
    private(set) var searchQuery = ""
    private(set) var searchScope: SearchScope = .allMail
    private var searchList = MergedList()
    private(set) var isSearching = false
    private(set) var searchError: String?
    private var searchVersion = 0
    @ObservationIgnored private var folderListCache: (revisions: [ReaderRevision], list: MergedList)?
    @ObservationIgnored private var searchTokens: [String: String] = [:]
    @ObservationIgnored private var searchGeneration = Generation()

    @ObservationIgnored private var cache: GmailCache?
    @ObservationIgnored private let persistsMail: Bool
    @ObservationIgnored private let syncsInBackground: Bool
    @ObservationIgnored private let makeAPI: (@MainActor (String) -> any GmailReading)?

    /// `makeAPI` supplies local mail; `cache` lets regression mode/tests use SQLite without opening the real database.
    init(accounts: AccountStore, persistsMail: Bool = true, syncsInBackground: Bool = true,
         cache: GmailCache? = nil, makeAPI: (@MainActor (String) -> any GmailReading)? = nil) {
        self.accounts = accounts
        self.persistsMail = persistsMail
        self.syncsInBackground = syncsInBackground
        self.cache = cache
        self.makeAPI = makeAPI
        isPreparing = persistsMail && cache == nil
    }

    // MARK: Lifecycle

    func prepare() async {
        defer { isPreparing = false }
        guard persistsMail, cache == nil else { return }
        do {
            cache = try await GmailCache.open()
        } catch {
            Log.cache.error("Could not open the mail cache: \(error.localizedDescription)")
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
                Log.cache.error("Could not open the account cache: \(error.localizedDescription)")
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
            Log.cache.error("Could not delete the account's cached mail: \(error.localizedDescription)")
            // Do not claim a successful removal while leaving an offline copy of the mail behind.
            accounts.error = String(localized: "Unable to remove locally cached mail. The account was not removed.")
            return
        }
        Log.accounts.info("Removed an account and its cached mail")
        sessions.first { $0.id == id }?.stop()
        sessions.removeAll { $0.id == id }
        accounts.remove(id)
        await AttachmentFiles.removeAll(accountID: id)
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
                group.addTask {
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
        if isSearchActive {
            if !isSearching { await search(pageAfter: true) }
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for session in sessions where session.reader.nextPageToken != nil {
                let reader = session.reader
                group.addTask { await reader.loadMore() }
            }
        }
    }

    // MARK: Merged state

    private struct ReaderRevision: Equatable {
        let accountID: String
        let revision: Int
    }

    /// What the list shows: search results while searching, else the folder's conversations from every account, newest first.
    /// Merging and sorting happen only when an account's conversations actually changed, however often the views read this.
    var list: MergedList { isSearchActive ? searchList : folderList }
    var conversations: [MergedConversation] { list.conversations }
    var conversationKeys: [ConversationKey] { list.keys }
    var searchResults: [MergedConversation] { searchList.conversations }

    private var folderList: MergedList {
        let revisions = sessions.map { ReaderRevision(accountID: $0.id, revision: $0.reader.conversationsRevision) }
        if let cache = folderListCache, cache.revisions == revisions { return cache.list }
        let merged = sessions.flatMap { session in
            session.reader.conversations.map {
                MergedConversation(key: ConversationKey(accountID: session.id, threadID: $0.id), conversation: $0)
            }
        }
        .sorted { $0.conversation.latestDate > $1.conversation.latestDate }
        let list = MergedList(merged)
        folderListCache = (revisions, list)
        return list
    }

    // MARK: Search

    var isSearchActive: Bool { !searchQuery.isEmpty }

    /// Switches the list to search mode (or back) right away. `performSearch` then fetches the results.
    func setSearch(_ text: String, scope: SearchScope) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != searchQuery || scope != searchScope else { return }
        searchGeneration.advance()
        searchQuery = query
        searchScope = scope
        searchError = nil
        isSearching = !query.isEmpty
        if query.isEmpty { searchList = MergedList(); searchTokens = [:] }
        searchVersion += 1
    }

    /// Asks every account for the first page of results. Results appear as each account answers.
    func performSearch() async { await search(pageAfter: false) }

    private func search(pageAfter: Bool) async {
        let query = searchQuery
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        let folder: Mailbox? = searchScope == .folder ? mailbox : nil
        let targets = sessions.filter { $0.reader.canSearch && (!pageAfter || searchTokens[$0.id] != nil) }
        isSearching = true
        searchError = nil
        var collected = pageAfter ? searchResults : []
        var failures: [String] = []
        if !pageAfter { searchTokens = [:] }
        await withTaskGroup(of: (String, Result<GmailPage, Error>).self) { group in
            for session in targets {
                let reader = session.reader
                let id = session.id
                let token = pageAfter ? searchTokens[id] : nil
                group.addTask {
                    do { return (id, .success(try await reader.search(query, in: folder, pageToken: token))) }
                    catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard searchGeneration == generation, !Task.isCancelled else { group.cancelAll(); return }
                switch result {
                case .success(let page):
                    searchTokens[id] = page.nextPageToken
                    let known = Set(collected.map(\.key))
                    collected += page.conversations
                        .map { MergedConversation(key: ConversationKey(accountID: id, threadID: $0.id), conversation: $0) }
                        .filter { !known.contains($0.key) }
                    collected.sort { $0.conversation.latestDate > $1.conversation.latestDate }
                    searchList = MergedList(collected)
                    searchVersion += 1
                case .failure(let error):
                    if !(error is CancellationError) { failures.append(error.localizedDescription) }
                }
            }
        }
        guard searchGeneration == generation, !Task.isCancelled else { return }
        if pageAfter == false, targets.isEmpty { searchList = MergedList() }
        searchError = failures.first
        isSearching = false
    }

    private func updateSearchResult(_ key: ConversationKey, _ change: (GmailConversation) -> GmailConversation) {
        guard let current = searchList[key] else { return }
        searchList = MergedList(searchResults.map {
            $0.key == key ? MergedConversation(key: key, conversation: change(current.conversation)) : $0
        })
        searchVersion += 1
    }

    private func removeSearchResult(_ key: ConversationKey) {
        guard searchList[key] != nil else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            searchList = MergedList(searchResults.filter { $0.key != key })
            searchVersion += 1
        }
    }

    var unreadInboxCount: Int? {
        let counts = sessions.compactMap(\.reader.unreadInboxCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    var isLoadingMailbox: Bool { isSearchActive ? isSearching : sessions.contains { $0.reader.isLoadingMailbox } }
    var isRestoringCache: Bool { sessions.contains { $0.reader.isRestoringCache } }
    var showingCachedMail: Bool { !isSearchActive && sessions.contains { $0.reader.showingCachedMail } }
    var hasMorePages: Bool { isSearchActive ? !searchTokens.isEmpty : sessions.contains { $0.reader.nextPageToken != nil } }
    var lastRefreshed: Date? { sessions.compactMap(\.reader.lastRefreshed).min() }
    var mailboxVersion: Int { sessions.reduce(searchVersion) { $0 + $1.reader.mailboxVersion } }
    var loadedCount: Int { list.conversations.count }
    var hasMultipleAccounts: Bool { sessions.count > 1 }

    var sendingAccounts: [SendingAccount] {
        sessions.filter { $0.reader.canSend && !isDisconnected($0.id) }.map { SendingAccount(id: $0.id, email: $0.email) }
    }

    /// Where new messages come from unless the person picks another account.
    var defaultSendingAccount: SendingAccount? {
        let candidates = sendingAccounts
        return candidates.first { $0.id == accounts.defaultAccount?.id } ?? candidates.first
    }

    /// A local copy of the attachment, downloaded the first time it is needed.
    func attachmentFile(_ attachment: MailAttachment, accountID: String) async throws -> URL {
        guard let reader = session(for: accountID)?.reader, reader.canLoadAttachments else { throw GmailError.permissionRequired }
        let url = AttachmentFiles.url(for: attachment, accountID: accountID)
        if AttachmentFiles.exists(at: url) { return url }
        Log.attachments.info("Downloading attachment of \(attachment.size, privacy: .public) bytes, \(attachment.mimeType, privacy: .public)")
        do {
            try await AttachmentFiles.store(try await reader.attachmentData(attachment), at: url)
        } catch {
            Log.attachments.error("Attachment download failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        return url
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
        if let searchError, isSearchActive {
            notices.append(HubNotice(id: "search", message: searchError, isError: true, fix: .retry))
        }
        return notices
    }

    // MARK: One conversation

    private func session(for accountID: String) -> AccountSession? {
        sessions.first { $0.id == accountID }
    }

    func conversation(for key: ConversationKey) -> GmailConversation? {
        searchResult(key) ?? folderList[key]?.conversation
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

    /// Search results come from any folder, so what can be done depends on the thread's own labels.
    private func searchResult(_ key: ConversationKey?) -> GmailConversation? {
        guard isSearchActive, let key else { return nil }
        return searchList[key]?.conversation
    }

    func canArchive(_ key: ConversationKey?) -> Bool {
        guard let key else { return false }
        if isSearchActive {
            return searchResult(key)?.labelIDs.contains("INBOX") == true && canModifyLabels(key)
        }
        return session(for: key.accountID)?.reader.canArchive ?? false
    }

    func canTrash(_ key: ConversationKey?) -> Bool {
        guard let key else { return false }
        if isSearchActive {
            guard let labels = searchResult(key)?.labelIDs else { return false }
            return !labels.contains("TRASH") && canModifyLabels(key)
        }
        return session(for: key.accountID)?.reader.canTrash ?? false
    }

    /// Opens a conversation in its account and closes whatever another account had open.
    func select(_ key: ConversationKey?) async {
        for session in sessions where session.id != key?.accountID { await session.reader.select(nil) }
        guard let key, let session = session(for: key.accountID) else { return }
        await session.reader.select(key.threadID)
    }

    @discardableResult
    func archive(_ key: ConversationKey, onRemoved: () -> Void = {}) async -> Bool {
        let generation = searchGeneration
        return await session(for: key.accountID)?.reader.archive(key.threadID, fromAnyFolder: isSearchActive) {
            if self.searchGeneration == generation { self.removeSearchResult(key) }
            onRemoved()
        } ?? false
    }

    @discardableResult
    func trash(_ key: ConversationKey, onRemoved: () -> Void = {}) async -> Bool {
        let generation = searchGeneration
        return await session(for: key.accountID)?.reader.trash(key.threadID, fromAnyFolder: isSearchActive) {
            if self.searchGeneration == generation { self.removeSearchResult(key) }
            onRemoved()
        } ?? false
    }

    func setUnread(_ key: ConversationKey, _ unread: Bool) async {
        guard let reader = session(for: key.accountID)?.reader else { return }
        await reader.setUnread(key.threadID, unread)
        if reader.mailboxError == nil { updateSearchResult(key) { $0.setting("UNREAD", to: unread) } }
    }

    func setStarred(_ key: ConversationKey, _ starred: Bool) async {
        guard let reader = session(for: key.accountID)?.reader else { return }
        await reader.setStarred(key.threadID, starred)
        if reader.mailboxError == nil { updateSearchResult(key) { $0.setting("STARRED", to: starred) } }
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
