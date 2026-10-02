import Foundation
import Observation

@MainActor
@Observable
final class GmailReaderStore {
    private(set) var mailbox: Mailbox
    private(set) var unreadInboxCount: Int?
    private(set) var conversations: [GmailConversation] = []
    private(set) var nextPageToken: String?
    private(set) var isLoadingMailbox = false
    private(set) var mailboxError: String?
    private(set) var mailboxVersion = 0
    private(set) var selectedConversation: GmailConversation?
    private(set) var isLoadingConversation = false
    private(set) var conversationError: String?
    private(set) var cacheError: String?
    private(set) var isRestoringCache = false
    private(set) var showingCachedMail = false
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private let api: any GmailReading
    @ObservationIgnored private let cache: GmailCacheSession?
    @ObservationIgnored private let synchronizer: GmailSyncCoordinator?
    @ObservationIgnored private var restoredSession: UUID?
    @ObservationIgnored private var bodies: [String: GmailConversation] = [:]
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var selection = UUID()
    @ObservationIgnored private var unreadCountRequest = UUID()
    @ObservationIgnored private var unreadCountSession = UUID()

    init(api: any GmailReading, mailbox: Mailbox = .inbox, cache: GmailCacheSession? = nil) {
        self.api = api
        self.mailbox = mailbox
        self.cache = cache
        if let cache, let syncAPI = api as? any GmailSyncReading {
            synchronizer = GmailSyncCoordinator(api: syncAPI, cache: cache)
        } else { synchronizer = nil }
    }

    func changeMailbox(_ mailbox: Mailbox) {
        guard self.mailbox != mailbox else { return }
        resetMailbox()
        self.mailbox = mailbox
    }

    func reset() {
        synchronizer?.cancel()
        resetMailbox()
        mailbox = .inbox
        unreadInboxCount = nil
        unreadCountRequest = UUID()
        unreadCountSession = UUID()
    }

    private func resetMailbox() {
        session = UUID()
        selection = UUID()
        restoredSession = nil
        conversations = []
        bodies = [:]
        nextPageToken = nil
        isLoadingMailbox = false
        isRestoringCache = false
        isLoadingConversation = false
        mailboxError = nil
        conversationError = nil
        selectedConversation = nil
        lastRefreshed = nil
        showingCachedMail = false
        mailboxVersion += 1
    }

    // The UI calls this before starting its network refresh, so a slow or failed
    // connection never prevents the previously loaded folder from appearing.
    func restoreCachedMailbox() async {
        guard let cache, restoredSession != session, !isRestoringCache else { return }
        let currentSession = session
        let currentAccount = unreadCountSession
        let currentMailbox = mailbox
        isRestoringCache = true
        defer { if session == currentSession { isRestoringCache = false } }
        do {
            let saved = try await cache.loadMailbox(currentMailbox)
            try Task.checkCancellation()
            guard session == currentSession else { return }
            if let saved {
                conversations = saved.conversations
                nextPageToken = saved.nextPageToken
                lastRefreshed = saved.fetchedAt
                showingCachedMail = true
                mailboxVersion += 1
            }
            if unreadInboxCount == nil {
                let count = try await cache.unreadCount()
                guard unreadCountSession == currentAccount, session == currentSession else { return }
                if unreadInboxCount == nil { unreadInboxCount = count }
            }
            restoredSession = currentSession
        } catch {
            guard session == currentSession, !Task.isCancelled else { return }
            cacheError = "Unable to read the local mail cache. Online mail is still available."
        }
    }

    func refresh() async {
        let currentSession = session
        await restoreCachedMailbox()
        guard session == currentSession, !Task.isCancelled else { return }
        let accountSession = unreadCountSession
        async let unreadCount: Void = refreshUnreadCount(for: accountSession)
        if let synchronizer { await synchronize(using: synchronizer) }
        else { await loadPage(refreshing: true) }
        await unreadCount
    }

    private func synchronize(using synchronizer: GmailSyncCoordinator) async {
        guard !isLoadingMailbox else { return }
        let currentSession = session
        let currentMailbox = mailbox
        isLoadingMailbox = true
        mailboxError = nil
        defer { if session == currentSession { isLoadingMailbox = false } }
        do {
            try await synchronizer.synchronize(mailbox: currentMailbox)
            let saved = try await cache?.loadMailbox(currentMailbox)
            try Task.checkCancellation()
            guard session == currentSession else { return }
            let changed = saved.map { $0.conversations != conversations } ?? false
            if let saved {
                conversations = saved.conversations
                nextPageToken = saved.nextPageToken
                lastRefreshed = saved.fetchedAt
            }
            showingCachedMail = false
            cacheError = nil
            if changed {
                selection = UUID()
                isLoadingConversation = false
                if let id = selectedConversation?.id { selectedConversation = conversations.first { $0.id == id } }
                bodies = [:]
                mailboxVersion += 1
            }
        } catch {
            guard session == currentSession, !Task.isCancelled, !(error is CancellationError) else { return }
            mailboxError = error.localizedDescription
        }
    }

    var canArchive: Bool { mailbox == .inbox && api is any GmailMutating }
    var canTrash: Bool { ![.trash, .outbox].contains(mailbox) && api is any GmailMutating }

    /// Archives or trashes a conversation, then drops it from the loaded list right away.
    /// Returns false (with `mailboxError` set) when Gmail rejects the change.
    @discardableResult
    func archive(_ id: String) async -> Bool {
        guard canArchive, let api = api as? any GmailMutating else { return false }
        return await mutate(id) { try await api.archive(threadID: id) }
    }

    @discardableResult
    func trash(_ id: String) async -> Bool {
        guard canTrash, let api = api as? any GmailMutating else { return false }
        return await mutate(id) { try await api.trash(threadID: id) }
    }

    var canSend: Bool { api is any GmailSending }

    /// Sends through Gmail. Sent mail and reply threads are picked up by a background refresh.
    func send(_ message: OutgoingMessage) async throws {
        guard let api = api as? any GmailSending else { throw GmailError.permissionRequired }
        try await api.send(message)
        Task { await refresh() }
    }

    var canModifyLabels: Bool { api is any GmailMutating }

    func setStarred(_ id: String, _ starred: Bool) async { await setLabel("STARRED", starred, id) }
    func setUnread(_ id: String, _ unread: Bool) async { await setLabel("UNREAD", unread, id) }

    private func setLabel(_ label: String, _ on: Bool, _ id: String) async {
        guard let api = api as? any GmailMutating else { return }
        let currentSession = session
        do { try await api.setLabel(label, on: on, threadID: id) }
        catch {
            guard session == currentSession else { return }
            mailboxError = error.localizedDescription
            return
        }
        guard session == currentSession else { return }
        mailboxError = nil
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index] = conversations[index].setting(label, to: on)
        }
        if let selected = selectedConversation, selected.id == id { selectedConversation = selected.setting(label, to: on) }
        if let cached = bodies[id] { bodies[id] = cached.setting(label, to: on) }
        // Persist through Gmail history and refresh the unread badge.
        await refresh()
    }

    private func mutate(_ id: String, _ change: () async throws -> Void) async -> Bool {
        let currentSession = session
        do {
            try await change()
        } catch {
            guard session == currentSession else { return false }
            mailboxError = error.localizedDescription
            return false
        }
        guard session == currentSession else { return true }
        mailboxError = nil
        conversations.removeAll { $0.id == id }
        if selectedConversation?.id == id { selectedConversation = nil }
        bodies[id] = nil
        mailboxVersion += 1
        // Reconcile the cache and unread badge with Gmail's history.
        await refresh()
        return true
    }

    func refreshUnreadCount() async {
        await refreshUnreadCount(for: unreadCountSession)
    }

    private func refreshUnreadCount(for accountSession: UUID) async {
        guard unreadCountSession == accountSession, !Task.isCancelled else { return }
        let request = UUID()
        unreadCountRequest = request
        do {
            let count = try await api.unreadInboxCount()
            try Task.checkCancellation()
            guard unreadCountSession == accountSession, unreadCountRequest == request else { return }
            unreadInboxCount = count
            if let cache {
                do { try await cache.saveUnreadCount(count) }
                catch {
                    guard unreadCountSession == accountSession, !Task.isCancelled else { return }
                    cacheError = "Unable to save the local unread count."
                }
            }
        } catch {
            // Preserve the last known (possibly persisted) count on failure.
        }
    }

    func loadMore() async {
        guard nextPageToken != nil else { return }
        await loadPage(refreshing: false)
    }

    private func loadPage(refreshing: Bool) async {
        guard !isLoadingMailbox, mailbox != .outbox else { return }
        let currentSession = session
        let currentMailbox = mailbox
        let pageToken = refreshing ? nil : nextPageToken
        isLoadingMailbox = true
        mailboxError = nil
        defer { if session == currentSession { isLoadingMailbox = false } }
        do {
            let checkpoint = try? await cache?.checkpoint()
            let page = try await api.mailbox(currentMailbox, pageToken: pageToken)
            try Task.checkCancellation()
            guard session == currentSession else { return }
            let next = page.nextPageToken == pageToken ? nil : page.nextPageToken
            if let cache {
                do {
                    let saved = try await cache.savePage(
                        GmailPage(conversations: page.conversations, nextPageToken: next),
                        mailbox: currentMailbox, refreshing: refreshing, checkpoint: checkpoint
                    )
                    guard session == currentSession, !Task.isCancelled else { return }
                    conversations = saved.conversations
                    nextPageToken = saved.nextPageToken
                    lastRefreshed = saved.fetchedAt
                    showingCachedMail = false
                    cacheError = nil
                    if refreshing { mailboxVersion += 1 }
                    return
                } catch GmailCacheError.checkpointChanged {
                    guard session == currentSession, !Task.isCancelled else { return }
                    mailboxError = "Mail changed while loading this page. Please try again."
                    return
                } catch {
                    guard session == currentSession, !Task.isCancelled else { return }
                    cacheError = "Unable to save mail locally. Newly fetched mail may not be available offline."
                }
            }
            if refreshing {
                conversations = page.conversations
                bodies = [:]
                mailboxVersion += 1
            } else {
                let existing = Set(conversations.map(\.id))
                conversations += page.conversations.filter { !existing.contains($0.id) }
            }
            nextPageToken = next
            lastRefreshed = Date()
            showingCachedMail = false
        } catch {
            guard session == currentSession, !Task.isCancelled, !(error is CancellationError) else { return }
            mailboxError = error.localizedDescription
        }
    }

    func select(_ id: String?) async {
        // Background changes to other rows must not tear down an already-open,
        // complete conversation and reset its reading position.
        if synchronizer != nil, let id, let selectedConversation, selectedConversation.id == id,
           selectedConversation.messages.allSatisfy(\.bodyLoaded), conversationError == nil { return }
        selection = UUID()
        let currentSelection = selection
        let currentSession = session
        selectedConversation = nil
        conversationError = nil
        isLoadingConversation = false
        guard let id else { return }
        if let cache {
            do {
                let saved = try await cache.conversation(id: id)
                guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
                if let saved {
                    selectedConversation = saved
                    if saved.messages.allSatisfy(\.bodyLoaded) { return }
                }
            } catch {
                guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
                cacheError = "Unable to read the locally saved message."
            }
        } else if let cached = bodies[id] {
            selectedConversation = cached
            return
        }
        isLoadingConversation = true
        defer { if selection == currentSelection { isLoadingConversation = false } }
        do {
            let checkpoint = try? await cache?.checkpoint()
            let conversation = try await api.conversation(id: id)
            try Task.checkCancellation()
            guard session == currentSession, selection == currentSelection else { return }
            if let cache {
                do { try await cache.saveConversation(conversation, checkpoint: checkpoint) }
                catch GmailCacheError.checkpointChanged {
                    guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
                    let saved = try? await cache.conversation(id: id)
                    guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
                    selectedConversation = saved
                    return
                } catch {
                    guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
                    cacheError = "Unable to save this message for offline reading."
                }
                guard session == currentSession, selection == currentSelection, !Task.isCancelled else { return }
            }
            bodies[id] = conversation
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index] = conversation
            }
            selectedConversation = conversation
        } catch {
            guard session == currentSession, selection == currentSelection, !Task.isCancelled, !(error is CancellationError) else { return }
            // Keep cached bodies visible even when a newly added reply cannot be downloaded.
            conversationError = error.localizedDescription
        }
    }
}
