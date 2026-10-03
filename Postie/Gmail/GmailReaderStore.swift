import Foundation
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class GmailReaderStore {
    private(set) var mailbox: Mailbox
    private(set) var unreadInboxCount: Int?
    private(set) var conversations: [GmailConversation] = [] {
        didSet { conversationsRevision &+= 1 }
    }
    /// Changes whenever `conversations` does, so a merged view of several readers can tell when to rebuild.
    private(set) var conversationsRevision = 0
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
    // What the account's API can do, worked out once instead of casting on every call.
    @ObservationIgnored private let mutator: (any GmailMutating)?
    @ObservationIgnored private let searcher: (any GmailSearching)?
    @ObservationIgnored private let attachmentLoader: (any GmailAttachmentLoading)?
    @ObservationIgnored private let sender: (any GmailSending)?
    @ObservationIgnored private let cache: GmailCacheSession?
    @ObservationIgnored private let synchronizer: GmailSyncCoordinator?
    @ObservationIgnored private var restoredGeneration: Generation?
    @ObservationIgnored private var bodies: [String: GmailConversation] = [:]
    // Work remembers the generation it started under and checks it again after every await: a changed
    // value means the folder, the open conversation or the whole account was reset in the meantime.
    @ObservationIgnored private var folderGeneration = Generation()
    @ObservationIgnored private var selectionGeneration = Generation()
    @ObservationIgnored private var accountGeneration = Generation()
    @ObservationIgnored private var unreadCountGeneration = Generation()

    init(api: any GmailReading, mailbox: Mailbox = .inbox, cache: GmailCacheSession? = nil) {
        self.api = api
        mutator = api as? any GmailMutating
        searcher = api as? any GmailSearching
        attachmentLoader = api as? any GmailAttachmentLoading
        sender = api as? any GmailSending
        self.mailbox = mailbox
        self.cache = cache
        if let cache, let syncAPI = api as? any GmailSyncReading {
            synchronizer = GmailSyncCoordinator(api: syncAPI, cache: cache)
        } else { synchronizer = nil }
    }

    /// Whether work started under these tokens still matters: the folder, the account's reader and the open
    /// conversation have not been reset since, and the task was not cancelled.
    private func isCurrent(_ startedFolder: Generation, selection startedSelection: Generation? = nil) -> Bool {
        guard folderGeneration == startedFolder, !Task.isCancelled else { return false }
        return startedSelection.map { selectionGeneration == $0 } ?? true
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
        unreadCountGeneration.advance()
        accountGeneration.advance()
    }

    private func resetMailbox() {
        folderGeneration.advance()
        selectionGeneration.advance()
        restoredGeneration = nil
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
        guard let cache, restoredGeneration != folderGeneration, !isRestoringCache else { return }
        let startedFolder = folderGeneration
        let startedAccount = accountGeneration
        let currentMailbox = mailbox
        isRestoringCache = true
        defer { if folderGeneration == startedFolder { isRestoringCache = false } }
        do {
            let saved = try await cache.loadMailbox(currentMailbox)
            try Task.checkCancellation()
            guard folderGeneration == startedFolder else { return }
            if let saved {
                conversations = saved.conversations
                nextPageToken = saved.nextPageToken
                lastRefreshed = saved.fetchedAt
                showingCachedMail = true
                mailboxVersion += 1
            }
            if unreadInboxCount == nil {
                let count = try await cache.unreadCount()
                guard accountGeneration == startedAccount, folderGeneration == startedFolder else { return }
                if unreadInboxCount == nil { unreadInboxCount = count }
            }
            restoredGeneration = startedFolder
        } catch {
            Log.cache.error("Could not read the cached folder: \(error.localizedDescription)")
            guard isCurrent(startedFolder) else { return }
            cacheError = String(localized: "Unable to read the local mail cache. Online mail is still available.")
        }
    }

    func refresh() async {
        let startedFolder = folderGeneration
        await restoreCachedMailbox()
        guard isCurrent(startedFolder) else { return }
        let startedAccount = accountGeneration
        async let unreadCount: Void = refreshUnreadCount(for: startedAccount)
        if let synchronizer { await synchronize(using: synchronizer) }
        else { await loadPage(refreshing: true) }
        await unreadCount
    }

    private func synchronize(using synchronizer: GmailSyncCoordinator) async {
        guard !isLoadingMailbox else { return }
        let startedFolder = folderGeneration
        let currentMailbox = mailbox
        isLoadingMailbox = true
        mailboxError = nil
        defer { if folderGeneration == startedFolder { isLoadingMailbox = false } }
        do {
            try await synchronizer.synchronize(mailbox: currentMailbox)
            let saved = try await cache?.loadMailbox(currentMailbox)
            try Task.checkCancellation()
            guard folderGeneration == startedFolder else { return }
            let changed = saved.map { $0.conversations != conversations } ?? false
            if let saved {
                conversations = saved.conversations
                nextPageToken = saved.nextPageToken
                lastRefreshed = saved.fetchedAt
            }
            showingCachedMail = false
            cacheError = nil
            if changed {
                selectionGeneration.advance()
                isLoadingConversation = false
                if let id = selectedConversation?.id { selectedConversation = conversations.first { $0.id == id } }
                bodies = [:]
                mailboxVersion += 1
            }
        } catch {
            guard isCurrent(startedFolder), !(error is CancellationError) else { return }
            Log.sync.error("Loading the folder failed: \(error.localizedDescription)")
            mailboxError = error.localizedDescription
        }
    }

    var canArchive: Bool { mailbox == .inbox && mutator != nil }
    var canTrash: Bool { ![.trash, .outbox].contains(mailbox) && mutator != nil }
    var canSearch: Bool { searcher != nil }

    /// One page of Gmail search results. Nothing is cached or added to the folder list.
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        guard let searcher else { throw GmailError.permissionRequired }
        return try await searcher.search(query, in: mailbox, pageToken: pageToken)
    }

    /// Archives or trashes a conversation, then drops it from the loaded list right away.
    /// Returns false (with `mailboxError` set) when Gmail rejects the change.
    @discardableResult
    func archive(_ id: String, fromAnyFolder: Bool = false, onRemoved: () -> Void = {}) async -> Bool {
        guard fromAnyFolder ? canModifyLabels : canArchive, let mutator else { return false }
        return await mutate(id, onRemoved: onRemoved) { try await mutator.archive(threadID: id) }
    }

    @discardableResult
    func trash(_ id: String, fromAnyFolder: Bool = false, onRemoved: () -> Void = {}) async -> Bool {
        guard fromAnyFolder ? canModifyLabels : canTrash, let mutator else { return false }
        return await mutate(id, onRemoved: onRemoved) { try await mutator.trash(threadID: id) }
    }

    var canLoadAttachments: Bool { attachmentLoader != nil }

    func attachmentData(_ attachment: MailAttachment) async throws -> Data {
        guard let attachmentLoader else { throw GmailError.permissionRequired }
        return try await attachmentLoader.attachmentData(attachment)
    }

    var canSend: Bool { sender != nil }

    /// People from this account's cached mail whose name or address matches `query`.
    func contacts(matching query: String, excluding ownEmail: String) async -> [ContactSuggestion] {
        guard let cache, !query.isEmpty else { return [] }
        do {
            return ContactBook.suggestions(from: try await cache.contactSources(matching: query), matching: query, excluding: ownEmail)
        } catch {
            Log.cache.error("Could not look up contacts: \(error.localizedDescription)")
            return []
        }
    }

    /// Sends through Gmail. Sent mail and reply threads are picked up by a background refresh.
    func send(_ message: OutgoingMessage) async throws {
        guard let sender else { throw GmailError.permissionRequired }
        try await sender.send(message)
        Task { await refresh() }
    }

    var canModifyLabels: Bool { mutator != nil }

    func setStarred(_ id: String, _ starred: Bool) async { await setLabel("STARRED", starred, id) }
    func setUnread(_ id: String, _ unread: Bool) async { await setLabel("UNREAD", unread, id) }

    private func setLabel(_ label: String, _ on: Bool, _ id: String) async {
        guard let mutator else { return }
        let startedFolder = folderGeneration
        do { try await mutator.setLabel(label, on: on, threadID: id) }
        catch {
            guard folderGeneration == startedFolder else { return }
            Log.api.error("Changing a label failed: \(error.localizedDescription)")
            mailboxError = error.localizedDescription
            return
        }
        guard folderGeneration == startedFolder else { return }
        mailboxError = nil
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index] = conversations[index].setting(label, to: on)
        }
        if let selected = selectedConversation, selected.id == id { selectedConversation = selected.setting(label, to: on) }
        if let cached = bodies[id] { bodies[id] = cached.setting(label, to: on) }
        // Persist through Gmail history and refresh the unread badge.
        await refresh()
    }

    private func mutate(_ id: String, onRemoved: () -> Void, _ change: () async throws -> Void) async -> Bool {
        let startedFolder = folderGeneration
        do {
            try await change()
        } catch {
            guard folderGeneration == startedFolder else { return false }
            Log.api.error("Archiving or trashing failed: \(error.localizedDescription)")
            mailboxError = error.localizedDescription
            return false
        }
        guard folderGeneration == startedFolder else { return true }
        mailboxError = nil
        // Animate so the row slides out and its neighbors close the gap, like Mail.
        withAnimation(.easeInOut(duration: 0.25)) {
            conversations.removeAll { $0.id == id }
            if selectedConversation?.id == id { selectedConversation = nil }
            bodies[id] = nil
            mailboxVersion += 1
            // Reconcile UI selection in the same transaction, not after the network refresh.
            onRemoved()
        }
        // Reconcile the cache and unread badge with Gmail's history.
        await refresh()
        return true
    }

    func refreshUnreadCount() async {
        await refreshUnreadCount(for: accountGeneration)
    }

    private func refreshUnreadCount(for startedAccount: Generation) async {
        guard accountGeneration == startedAccount, !Task.isCancelled else { return }
        unreadCountGeneration.advance()
        let request = unreadCountGeneration
        do {
            let count = try await api.unreadInboxCount()
            try Task.checkCancellation()
            guard accountGeneration == startedAccount, unreadCountGeneration == request else { return }
            unreadInboxCount = count
            if let cache {
                do { try await cache.saveUnreadCount(count) }
                catch {
                    Log.cache.error("Could not save the unread count: \(error.localizedDescription)")
                    guard accountGeneration == startedAccount, !Task.isCancelled else { return }
                    cacheError = String(localized: "Unable to save the local unread count.")
                }
            }
        } catch {
            // Preserve the last known (possibly persisted) count on failure.
            if !(error is CancellationError) { Log.api.error("Could not refresh the unread count: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func loadMore() async {
        guard nextPageToken != nil else { return }
        await loadPage(refreshing: false)
    }

    private func loadPage(refreshing: Bool) async {
        guard !isLoadingMailbox, mailbox != .outbox else { return }
        let startedFolder = folderGeneration
        let currentMailbox = mailbox
        let pageToken = refreshing ? nil : nextPageToken
        isLoadingMailbox = true
        mailboxError = nil
        defer { if folderGeneration == startedFolder { isLoadingMailbox = false } }
        do {
            let checkpoint = try? await cache?.checkpoint()
            let page = try await api.mailbox(currentMailbox, pageToken: pageToken)
            try Task.checkCancellation()
            guard folderGeneration == startedFolder else { return }
            let next = page.nextPageToken == pageToken ? nil : page.nextPageToken
            if let cache {
                do {
                    let saved = try await cache.savePage(
                        GmailPage(conversations: page.conversations, nextPageToken: next),
                        mailbox: currentMailbox, refreshing: refreshing, checkpoint: checkpoint
                    )
                    guard isCurrent(startedFolder) else { return }
                    conversations = saved.conversations
                    nextPageToken = saved.nextPageToken
                    lastRefreshed = saved.fetchedAt
                    showingCachedMail = false
                    cacheError = nil
                    if refreshing { mailboxVersion += 1 }
                    return
                } catch GmailCacheError.checkpointChanged {
                    guard isCurrent(startedFolder) else { return }
                    mailboxError = String(localized: "Mail changed while loading this page. Please try again.")
                    return
                } catch {
                    Log.cache.error("Could not save the fetched page: \(error.localizedDescription)")
                    guard isCurrent(startedFolder) else { return }
                    cacheError = String(localized: "Unable to save mail locally. Newly fetched mail may not be available offline.")
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
            guard isCurrent(startedFolder), !(error is CancellationError) else { return }
            Log.sync.error("Loading the folder failed: \(error.localizedDescription)")
            mailboxError = error.localizedDescription
        }
    }

    func select(_ id: String?) async {
        // Background changes to other rows must not tear down an already-open,
        // complete conversation and reset its reading position.
        if synchronizer != nil, let id, let selectedConversation, selectedConversation.id == id,
           selectedConversation.messages.allSatisfy(\.bodyLoaded), conversationError == nil { return }
        selectionGeneration.advance()
        let startedSelection = selectionGeneration
        let startedFolder = folderGeneration
        selectedConversation = nil
        conversationError = nil
        isLoadingConversation = false
        guard let id else { return }
        if let cache {
            do {
                let saved = try await cache.conversation(id: id)
                guard isCurrent(startedFolder, selection: startedSelection) else { return }
                if let saved {
                    selectedConversation = saved
                    if saved.messages.allSatisfy(\.bodyLoaded) { return }
                }
            } catch {
                Log.cache.error("Could not read the saved message: \(error.localizedDescription)")
                guard isCurrent(startedFolder, selection: startedSelection) else { return }
                cacheError = String(localized: "Unable to read the locally saved message.")
            }
        } else if let cached = bodies[id] {
            selectedConversation = cached
            return
        }
        isLoadingConversation = true
        defer { if selectionGeneration == startedSelection { isLoadingConversation = false } }
        do {
            let checkpoint = try? await cache?.checkpoint()
            let conversation = try await api.conversation(id: id)
            try Task.checkCancellation()
            guard folderGeneration == startedFolder, selectionGeneration == startedSelection else { return }
            if let cache {
                do { try await cache.saveConversation(conversation, checkpoint: checkpoint) }
                catch GmailCacheError.checkpointChanged {
                    guard isCurrent(startedFolder, selection: startedSelection) else { return }
                    let saved = try? await cache.conversation(id: id)
                    guard isCurrent(startedFolder, selection: startedSelection) else { return }
                    selectedConversation = saved
                    return
                } catch {
                    guard isCurrent(startedFolder, selection: startedSelection) else { return }
                    cacheError = String(localized: "Unable to save this message for offline reading.")
                }
                guard isCurrent(startedFolder, selection: startedSelection) else { return }
            }
            bodies[id] = conversation
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index] = conversation
            }
            selectedConversation = conversation
        } catch {
            guard isCurrent(startedFolder, selection: startedSelection), !(error is CancellationError) else { return }
            Log.api.error("Loading the conversation failed: \(error.localizedDescription)")
            // Keep cached bodies visible even when a newly added reply cannot be downloaded.
            conversationError = error.localizedDescription
        }
    }
}
