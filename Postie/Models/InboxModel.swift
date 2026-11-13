import Foundation
import Observation

/// What one Gmail reader window is doing: the selection, the search, the open composer and the
/// actions on a conversation. The views only render this; the hub owns the mail itself.
@MainActor
@Observable
final class InboxModel {
    let hub: MailHub
    var searchText = ""
    var searchScope: SearchScope = .allMail
    var composer: ComposeDraft?
    /// Why a draft could not be opened for editing.
    var draftError: String?
    /// Bumped to ask the conversation to be loaded again after a failure.
    private(set) var selectionRetry = 0
    /// Bumped when an explicit removal should hand keyboard focus back to the list.
    private(set) var listFocusRequest = 0
    /// Explicit toolbar/menu navigation reveals its row without stealing focus from the reader.
    private(set) var conversationNavigationRequest = 0
    private var selection = ConversationSelection<ConversationKey>()

    private(set) var isReaderActive = false
    @ObservationIgnored private var readerActivityRevision = 0
    @ObservationIgnored private let autoReadDelay: @MainActor () async throws -> Void
    @ObservationIgnored private var selectionBeforeSearch: ConversationKey?
    @ObservationIgnored private var manualUnreadRevision: Int?
    // Once a Gmail write begins it must survive view-task cancellation during its follow-up refresh.
    @ObservationIgnored private var autoReadTasks: [ConversationKey: Task<Void, Never>] = [:]

    init(hub: MailHub, autoReadDelay: @escaping @MainActor () async throws -> Void = {
        try await Task.sleep(for: .seconds(1))
    }) {
        self.hub = hub
        self.autoReadDelay = autoReadDelay
    }

    /// Activity belongs to the reader window, not another Postie window such as the composer.
    func setReaderActive(_ active: Bool) {
        guard isReaderActive != active else { return }
        isReaderActive = active
        readerActivityRevision += 1
    }

    // MARK: Selection

    var conversationKeys: [ConversationKey] { hub.conversationKeys }

    /// The selected conversation, as long as it is still in the list.
    var selectedID: ConversationKey? {
        selection.selectedID.flatMap { hub.list[$0] == nil ? nil : $0 }
    }

    func select(_ key: ConversationKey?) {
        selection.select(key)
    }

    func updateFromList(_ key: ConversationKey?) {
        selection.updateFromList(key, visibleIDs: conversationKeys)
    }

    func reconcileSelection() {
        selection.reconcile(with: conversationKeys)
    }

    func navigateConversation(offset: Int) {
        guard let key = selection.neighbor(offset: offset, visibleIDs: conversationKeys) else { return }
        select(key)
        conversationNavigationRequest += 1
    }

    func changeMailbox(_ mailbox: Mailbox) {
        guard mailbox != hub.mailbox else { return }
        selection.reset()
        searchText = ""
        selectionBeforeSearch = nil
        hub.changeMailbox(mailbox)
    }

    /// The fully loaded conversation that Reply and Forward act on. Its account is the one that sends the response.
    var openConversation: GmailConversation? {
        guard let selectedID, hub.sendingAccounts.contains(where: { $0.id == selectedID.accountID }),
              hub.mailbox != .outbox, hub.mailbox != .drafts else { return nil }
        return hub.openConversation(for: selectedID)
    }

    /// The selected conversation, when its labels can be changed.
    var selected: MergedConversation? {
        guard let selectedID, hub.canModifyLabels(selectedID),
              let conversation = hub.conversation(for: selectedID) else { return nil }
        return MergedConversation(key: selectedID, conversation: conversation)
    }

    /// Loads the selected conversation, then marks it read once it has stayed open for a moment.
    func openSelection() async {
        guard !Task.isCancelled else { return }
        let key = selectedID
        let revision = selection.revision
        let activityRevision = readerActivityRevision
        await hub.select(key)
        guard let key, !Task.isCancelled, selectedID == key, selection.revision == revision,
              isReaderActive, readerActivityRevision == activityRevision else { return }
        await markOpenedConversationRead(key, revision: revision, activityRevision: activityRevision)
    }

    func retrySelection() {
        selectionRetry += 1
    }

    /// Marks the open conversation read after it has stayed open briefly, so skimming past mail doesn't change it.
    private func markOpenedConversationRead(_ key: ConversationKey, revision: Int, activityRevision: Int) async {
        guard isReaderActive, readerActivityRevision == activityRevision, hub.canModifyLabels(key),
              manualUnreadRevision != revision, autoReadTasks[key] == nil,
              let conversation = hub.openConversation(for: key), conversation.isUnread,
              conversation.messages.allSatisfy(\.bodyLoaded) else { return }
        do { try await autoReadDelay() }
        catch { return }
        guard !Task.isCancelled, isReaderActive, readerActivityRevision == activityRevision,
              selectedID == key, selection.revision == revision,
              manualUnreadRevision != revision, autoReadTasks[key] == nil,
              hub.openConversation(for: key)?.isUnread == true else { return }

        let task = Task {
            // Recheck on entry: the window may deactivate before this unstructured task starts.
            guard isReaderActive, readerActivityRevision == activityRevision,
                  selectedID == key, selection.revision == revision, manualUnreadRevision != revision else { return }
            await hub.setUnread(key, false)
        }
        autoReadTasks[key] = task
        await task.value
        autoReadTasks[key] = nil
        // Recheck actual unread state next time: neither a failed attempt nor an earlier
        // successful read should block a newly arrived unread reply in this conversation.
    }

    // MARK: Loading

    func refresh() {
        Task { await hub.refresh(isUserInitiated: true) }
    }

    /// Tries again after an error, for whatever failed: the folder, the search or both.
    func retry() {
        refresh()
        if selectedID != nil { retrySelection() }
        if hub.isSearchActive { Task { await hub.performSearch() } }
    }

    func loadMore() {
        Task { await hub.loadMore() }
    }

    /// Loads the next page as the end of the list scrolls into view.
    func conversationAppeared(_ key: ConversationKey) {
        guard key == conversationKeys.last, hub.hasMorePages, !hub.isLoadingMailbox else { return }
        loadMore()
    }

    // MARK: Search

    struct SearchRequest: Hashable {
        let text: String
        let scope: SearchScope
    }

    var searchRequest: SearchRequest { SearchRequest(text: searchText, scope: searchScope) }

    /// Switches the list to search mode (or back) right away. Returns whether results should now be fetched.
    func applySearch() -> Bool {
        let wasSearching = hub.isSearchActive
        let willSearch = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !wasSearching, willSearch {
            // Save identity before changing which rows the hub exposes.
            selectionBeforeSearch = selection.selectedID
            selection.select(nil)
        }
        hub.setSearch(searchText, scope: searchScope)
        if wasSearching, !willSearch {
            if let previous = selectionBeforeSearch { selection.select(previous) }
            selectionBeforeSearch = nil
            reconcileSelection()
        }
        return hub.isSearchActive
    }

    // MARK: Actions on a conversation

    func toggleRead(_ item: MergedConversation) {
        let unread = !item.conversation.isUnread
        // Explicit unread wins for this opening, including a countdown already in progress.
        if unread, selectedID == item.key { manualUnreadRevision = selection.revision }
        let pendingRead = autoReadTasks[item.key]
        Task {
            // Serialize against an automatic write already sent to Gmail so the user's choice wins.
            if let pendingRead { _ = await pendingRead.value }
            await hub.setUnread(item.key, unread)
        }
    }

    func toggleStar(_ item: MergedConversation) {
        Task { await hub.setStarred(item.key, !item.conversation.isStarred) }
    }

    func isRemoving(_ key: ConversationKey) -> Bool { selection.isRemoving(key) }

    var canRemoveSelection: Bool {
        selectedID.map { !isRemoving($0) } ?? false
    }

    @discardableResult
    func remove(_ key: ConversationKey, archiving: Bool) -> Task<Void, Never>? {
        guard let token = selection.beginRemoval(of: key, visibleIDs: conversationKeys) else { return nil }
        let mailbox = hub.mailbox
        let query = hub.searchQuery
        let scope = hub.searchScope
        return Task {
            var removalRevision: Int?
            let onRemoved = { [self] in
                // Advance selection immediately. Remember that opening so rollback cannot override
                // a subsequent user choice, even if they leave and return to the same neighbor.
                if selection.finishRemoval(token, removed: true, visibleIDs: conversationKeys) {
                    removalRevision = selection.revision
                    if composer == nil { listFocusRequest += 1 }
                }
            }
            let accepted: Bool
            if archiving { accepted = await hub.archive(key, onRemoved: onRemoved) }
            else { accepted = await hub.trash(key, onRemoved: onRemoved) }
            selection.finishRemoval(token, removed: false, visibleIDs: conversationKeys)
            if !accepted, removalRevision == selection.revision,
               hub.mailbox == mailbox, hub.searchQuery == query, hub.searchScope == scope,
               hub.list[key] != nil {
                selection.select(key)
            }
        }
    }

    // MARK: Composing

    var canCompose: Bool { !hub.sendingAccounts.isEmpty }

    func newMessage() {
        composer = ComposeDraft(accountID: hub.defaultSendingAccount?.id)
    }

    func respond(_ kind: ComposeKind) {
        guard let key = selectedID, let conversation = openConversation,
              let accountEmail = hub.email(for: key.accountID) else { return }
        let thread = conversation.presentation(includingBodies: true, mailbox: hub.mailbox)
        var draft = kind == .forward
            ? ComposeDraft.forward(thread)
            : ComposeDraft.reply(to: thread, accountEmail: accountEmail, allRecipients: kind == .replyAll)
        draft.accountID = key.accountID
        draft.gmailThreadID = kind == .forward ? nil : key.threadID
        composer = draft
    }

    /// Opens a draft of the Drafts folder in a composer window.
    func editDraft(_ key: ConversationKey) {
        guard hub.canEditDraft(key) else { return }
        Task {
            do {
                if let draft = try await hub.openDraft(key) { composer = draft }
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    // MARK: Outbox

    /// Takes a queued message back into a composer window to change it.
    func editOutboxItem(_ key: ConversationKey) {
        guard hub.canActOnOutboxItem(key) else { return }
        Task {
            do {
                if let draft = try await hub.editOutboxItem(key) { composer = draft }
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    func retryOutboxItem(_ key: ConversationKey) {
        hub.retryOutboxItem(key)
    }

    func deleteOutboxItem(_ key: ConversationKey) {
        guard hub.canActOnOutboxItem(key) else { return }
        Task { await hub.deleteOutboxItem(key) }
    }

    // MARK: Menu and toolbar

    var mailActions: MailActions {
        let selectedID = selectedID
        let openConversation = openConversation
        let selected = selected
        return MailActions(
            currentMailbox: hub.mailbox,
            selectMailbox: { [self] in changeMailbox($0) },
            newMessage: canCompose ? { [self] in newMessage() } : nil,
            refresh: hub.isLoadingMailbox || hub.mailbox == .outbox ? nil : { [self] in refresh() },
            archive: canRemoveSelection && hub.canArchive(selectedID)
                ? { [self] in selectedID.map { remove($0, archiving: true) } } : nil,
            trash: canRemoveSelection && hub.canTrash(selectedID)
                ? { [self] in selectedID.map { remove($0, archiving: false) } } : nil,
            editDraft: selectedID.flatMap { key in hub.canEditDraft(key) ? { [self] in editDraft(key) } : nil },
            reply: openConversation == nil ? nil : { [self] in respond(.reply) },
            replyAll: openConversation == nil ? nil : { [self] in respond(.replyAll) },
            forward: openConversation.map { $0.messages.allSatisfy(\.bodyLoaded) } == true ? { [self] in respond(.forward) } : nil,
            toggleRead: selected.map { item in { [self] in toggleRead(item) } },
            toggleFlag: selected.map { item in { [self] in toggleStar(item) } },
            selectionIsUnread: selected?.conversation.isUnread ?? false,
            selectionIsFlagged: selected?.conversation.isStarred ?? false,
            previousConversation: selection.neighbor(offset: -1, visibleIDs: conversationKeys) == nil
                ? nil : { [self] in navigateConversation(offset: -1) },
            nextConversation: selection.neighbor(offset: 1, visibleIDs: conversationKeys) == nil
                ? nil : { [self] in navigateConversation(offset: 1) }
        )
    }
}
