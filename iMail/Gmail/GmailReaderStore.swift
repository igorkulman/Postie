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
    }

    func changeMailbox(_ mailbox: Mailbox) {
        guard self.mailbox != mailbox else { return }
        resetMailbox()
        self.mailbox = mailbox
    }

    func reset() {
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
        await loadPage(refreshing: true)
        await unreadCount
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
            let page = try await api.mailbox(currentMailbox, pageToken: pageToken)
            try Task.checkCancellation()
            guard session == currentSession else { return }
            let next = page.nextPageToken == pageToken ? nil : page.nextPageToken
            if let cache {
                do {
                    let saved = try await cache.savePage(
                        GmailPage(conversations: page.conversations, nextPageToken: next),
                        mailbox: currentMailbox, refreshing: refreshing
                    )
                    guard session == currentSession, !Task.isCancelled else { return }
                    conversations = saved.conversations
                    nextPageToken = saved.nextPageToken
                    lastRefreshed = saved.fetchedAt
                    showingCachedMail = false
                    cacheError = nil
                    if refreshing { mailboxVersion += 1 }
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
            let conversation = try await api.conversation(id: id)
            try Task.checkCancellation()
            guard session == currentSession, selection == currentSelection else { return }
            if let cache {
                do { try await cache.saveConversation(conversation) }
                catch {
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
