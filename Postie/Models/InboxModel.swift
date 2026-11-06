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
    /// Why the selected conversations could not be forwarded.
    var forwardError: String?
    private var isPreparingForward = false
    /// Bumped to ask the conversation to be loaded again after a failure.
    private(set) var selectionRetry = 0
    /// Bumped when an explicit removal should hand keyboard focus back to the list.
    private(set) var listFocusRequest = 0
    private var selection = ConversationSelection<ConversationKey>()
    /// The window's history, which also backs the Edit menu and undoing typing in the search field.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The undo or redo reaching Gmail last, which the next one waits for.
    @ObservationIgnored private var undoQueue: Task<Void, Never>?

    @ObservationIgnored private var selectionBeforeSearch: Set<ConversationKey> = []
    @ObservationIgnored private var autoReadID: ConversationKey?

    init(hub: MailHub) {
        self.hub = hub
    }

    // MARK: Selection

    var conversationKeys: [ConversationKey] { hub.conversationKeys }

    /// The conversation to open: the only selected one, as long as it is still in the list.
    var selectedID: ConversationKey? {
        selection.selectedID.flatMap { hub.list[$0] == nil ? nil : $0 }
    }

    /// Every selected conversation still in the list, in list order.
    var selectedKeys: [ConversationKey] {
        conversationKeys.filter(selection.selectedIDs.contains)
    }

    /// How many conversations are selected, counting those being removed so the count doesn't tick down meanwhile.
    var selectedCount: Int { selection.selectedIDs.count }

    func select(_ key: ConversationKey?) {
        selection.select(key)
    }

    func updateFromList(_ keys: Set<ConversationKey>) {
        selection.updateFromList(keys, visibleIDs: conversationKeys)
    }

    func reconcileSelection() {
        selection.reconcile(with: conversationKeys)
    }

    func changeMailbox(_ mailbox: Mailbox) {
        guard mailbox != hub.mailbox else { return }
        selection.reset()
        searchText = ""
        selectionBeforeSearch = []
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
        await hub.select(selectedID)
        await markOpenedConversationRead()
    }

    func retrySelection() {
        selectionRetry += 1
    }

    /// Marks the open conversation read after it has stayed open briefly, so skimming past mail doesn't change it.
    private func markOpenedConversationRead() async {
        guard let key = selectedID, hub.canModifyLabels(key), autoReadID != key else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, selectedID == key, hub.openConversation(for: key)?.isUnread == true else { return }
        autoReadID = key
        // Unstructured: the follow-up refresh must not be cancelled by a selection change.
        Task { await hub.setUnread(key, false) }
    }

    // MARK: Loading

    func refresh() {
        Task { await hub.refresh() }
    }

    /// Tries again after an error, for whatever failed: the folder, the search or both.
    func retry() {
        refresh()
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
            selectionBeforeSearch = selection.selectedIDs
            selection.select(nil)
        }
        hub.setSearch(searchText, scope: searchScope)
        if wasSearching, !willSearch {
            if !selectionBeforeSearch.isEmpty { selection.select(selectionBeforeSearch) }
            selectionBeforeSearch = []
            reconcileSelection()
        }
        return hub.isSearchActive
    }

    // MARK: Actions on a conversation

    func toggleRead(_ item: MergedConversation) {
        let unread = !item.conversation.isUnread
        changeLabel(.setUnread(item.key, unread), named: unread ? String(localized: "Mark as Unread") : String(localized: "Mark as Read"))
    }

    func toggleStar(_ item: MergedConversation) {
        let starred = !item.conversation.isStarred
        changeLabel(.setStarred(item.key, starred), named: starred ? String(localized: "Flag") : String(localized: "Unflag"))
    }

    private func changeLabel(_ change: MailChange, named name: String) {
        Task {
            if await apply(change) { recordUndo(change.opposite, named: name) }
        }
    }

    var canRemoveSelection: Bool {
        let keys = selectedKeys
        return !keys.isEmpty && !keys.contains(where: selection.isRemoving)
    }

    func remove(_ key: ConversationKey, archiving: Bool) {
        remove([key], archiving: archiving)
    }

    func remove(_ keys: [ConversationKey], archiving: Bool) {
        guard let token = selection.beginRemoval(of: Set(keys), visibleIDs: conversationKeys) else { return }
        let snapshots = hub.canUndoRemoval(archiving: archiving) ? hub.removedConversations(keys) : []
        Task {
            let removed = await removeRows(keys, archiving: archiving, token: token)
            let undoable = snapshots.filter { removed.contains($0.key) }
            if !undoable.isEmpty {
                recordUndo(.restore(undoable, archived: archiving), named: Self.removalName(count: undoable.count, archiving: archiving))
            }
            await hub.refresh(after: keys, succeeded: removed)
        }
    }

    private func removeRows(_ keys: [ConversationKey], archiving: Bool, anyFolder: Bool = false, token: UUID?) async -> [ConversationKey] {
        let removed = await hub.remove(keys, archiving: archiving, anyFolder: anyFolder) { [self] in
            // An explicit selected-thread removal returns keyboard navigation to the list,
            // including when it is empty. Background sync never steals search focus.
            if let token, selection.rowRemoved(token, visibleIDs: conversationKeys) { returnFocusToList() }
        }
        // Still pending when Gmail refused some of them, and those then stay selected.
        if let token, selection.finishRemoval(token, removed: !removed.isEmpty, visibleIDs: conversationKeys) { returnFocusToList() }
        return removed
    }

    private static func removalName(count: Int, archiving: Bool) -> String {
        if count == 1 { return archiving ? String(localized: "Archive") : String(localized: "Move to Trash") }
        return archiving ? String(localized: "Archive \(count) Conversations") : String(localized: "Move \(count) Conversations to Trash")
    }

    private func returnFocusToList() {
        if composer == nil { listFocusRequest += 1 }
    }

    /// The Delete key: queued messages are deleted, anything else goes to the Trash.
    func deleteSelection() {
        let keys = selectedKeys
        let queued = keys.filter(hub.canActOnOutboxItem)
        if !queued.isEmpty { queued.forEach(deleteOutboxItem) }
        else if !keys.isEmpty, keys.allSatisfy(hub.canTrash) { remove(keys, archiving: false) }
    }

    // MARK: Undo

    /// A change to mail that can be taken back. Taking it back records its opposite, which is what Redo then does.
    private enum MailChange {
        case remove([RemovedConversation], archiving: Bool)
        case restore([RemovedConversation], archived: Bool)
        case setUnread(ConversationKey, Bool)
        case setStarred(ConversationKey, Bool)

        var opposite: MailChange {
            switch self {
            case .remove(let items, let archiving): .restore(items, archived: archiving)
            case .restore(let items, let archived): .remove(items, archiving: archived)
            case .setUnread(let key, let unread): .setUnread(key, !unread)
            case .setStarred(let key, let starred): .setStarred(key, !starred)
            }
        }
    }

    /// Adds a step to the history, named for the Undo and Redo menu items.
    private func recordUndo(_ undo: MailChange, named name: String) {
        guard let undoManager else { return }
        // Gmail answers between input events, and until the next event automatic grouping would make
        // all its answers a single step. Undo and Redo have a group of their own open already.
        let needsOwnGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsOwnGroup {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.perform(undo, named: name) }
        }
        undoManager.setActionName(name)
        if needsOwnGroup {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = true
        }
    }

    /// Runs when Undo or Redo is chosen. Only while it runs does the opposite step go to the other side of
    /// the history, so that cannot wait for Gmail. Gmail hears about them one at a time, in the order chosen.
    private func perform(_ change: MailChange, named name: String) {
        let isUndoing = undoManager?.isUndoing == true
        recordUndo(change.opposite, named: name)
        let previous = undoQueue
        undoQueue = Task {
            await previous?.value
            // Offline, say: the error is on screen and Undo can be tried again later.
            if await !apply(change), isUndoing { recordUndo(change, named: name) }
        }
    }

    /// Makes the change in Gmail and on screen. Returns once Gmail has answered, whether or not it took all of it.
    private func apply(_ change: MailChange) async -> Bool {
        let keys: [ConversationKey]
        let succeeded: [ConversationKey]
        switch change {
        case .remove(let items, let archiving):
            keys = items.map(\.key)
            let token = selection.beginRemoval(of: Set(keys), visibleIDs: conversationKeys)
            succeeded = await removeRows(keys, archiving: archiving, anyFolder: true, token: token)
        case .restore(let items, let archived):
            keys = items.map(\.key)
            succeeded = await hub.restore(items, archived: archived)
            selectRestored(succeeded)
        case .setUnread(let key, let unread):
            keys = [key]
            succeeded = await hub.setUnread(key, unread, refreshing: false) ? [key] : []
        case .setStarred(let key, let starred):
            keys = [key]
            succeeded = await hub.setStarred(key, starred, refreshing: false) ? [key] : []
        }
        // Not awaited: the next undo should not have to wait for it.
        Task { await hub.refresh(after: keys, succeeded: succeeded) }
        return succeeded.count == keys.count
    }

    /// Like Mail, what comes back is selected, provided it came back to the list on screen.
    private func selectRestored(_ keys: [ConversationKey]) {
        let visible = Set(keys).intersection(conversationKeys)
        guard !visible.isEmpty else { return }
        // Undo puts things back as they were, so opening one this way must not mark it read.
        if visible.count == 1 { autoReadID = visible.first }
        selection.select(visible)
        returnFocusToList()
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

    /// Whether these conversations can go out together. Unlike one open conversation, their bodies load on demand.
    func canForward(_ keys: [ConversationKey]) -> Bool {
        !isPreparingForward && !keys.isEmpty && hub.mailbox != .outbox && hub.mailbox != .drafts
            && keys.allSatisfy { key in hub.sendingAccounts.contains { $0.id == key.accountID } }
    }

    /// Forwards conversations in one message, from the account of the first of them.
    func forward(_ keys: [ConversationKey]) {
        guard canForward(keys) else { return }
        isPreparingForward = true
        Task {
            defer { isPreparingForward = false }
            do {
                var threads: [MailThread] = []
                for key in keys {
                    threads.append(try await hub.fullConversation(key).presentation(includingBodies: true, mailbox: hub.mailbox))
                }
                var draft = ComposeDraft.forward(threads)
                draft.accountID = keys.first?.accountID
                composer = draft
            } catch {
                forwardError = error.localizedDescription
            }
        }
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
        let selectedKeys = selectedKeys
        let forwardsSeveral = selectedCount > 1
        return MailActions(
            currentMailbox: hub.mailbox,
            selectMailbox: { [self] in changeMailbox($0) },
            newMessage: canCompose ? { [self] in newMessage() } : nil,
            refresh: hub.isLoadingMailbox || hub.mailbox == .outbox ? nil : { [self] in refresh() },
            archive: canRemoveSelection && selectedKeys.allSatisfy(hub.canArchive)
                ? { [self] in remove(selectedKeys, archiving: true) } : nil,
            trash: canRemoveSelection && selectedKeys.allSatisfy(hub.canTrash)
                ? { [self] in remove(selectedKeys, archiving: false) } : nil,
            editDraft: selectedID.flatMap { key in hub.canEditDraft(key) ? { [self] in editDraft(key) } : nil },
            // Several conversations have no open one to answer, so only Forward stays available.
            reply: openConversation == nil ? nil : { [self] in respond(.reply) },
            replyAll: openConversation == nil ? nil : { [self] in respond(.replyAll) },
            forward: forwardsSeveral
                ? (canForward(selectedKeys) ? { [self] in forward(selectedKeys) } : nil)
                : (openConversation.map { $0.messages.allSatisfy(\.bodyLoaded) } == true ? { [self] in respond(.forward) } : nil),
            toggleRead: selected.map { item in { [self] in toggleRead(item) } },
            toggleFlag: selected.map { item in { [self] in toggleStar(item) } },
            selectionIsUnread: selected?.conversation.isUnread ?? false,
            selectionIsFlagged: selected?.conversation.isStarred ?? false
        )
    }
}
