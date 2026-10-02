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
    /// Bumped to ask the conversation to be loaded again after a failure.
    private(set) var selectionRetry = 0
    /// Bumped when an explicit removal should hand keyboard focus back to the list.
    private(set) var listFocusRequest = 0
    private var selection = ConversationSelection<ConversationKey>()

    @ObservationIgnored private var selectionBeforeSearch: ConversationKey?
    @ObservationIgnored private var autoReadID: ConversationKey?

    init(hub: MailHub) {
        self.hub = hub
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
              hub.mailbox != .outbox else { return nil }
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
        Task { await hub.setUnread(item.key, !item.conversation.isUnread) }
    }

    func toggleStar(_ item: MergedConversation) {
        Task { await hub.setStarred(item.key, !item.conversation.isStarred) }
    }

    var canRemoveSelection: Bool {
        selectedID.map { !selection.isRemoving($0) } ?? false
    }

    func remove(_ key: ConversationKey, archiving: Bool) {
        guard let token = selection.beginRemoval(of: key, visibleIDs: conversationKeys) else { return }
        Task {
            let onRemoved = { [self] in
                // An explicit selected-thread removal returns keyboard navigation to the list,
                // including when it is empty. Background sync never steals search focus.
                if selection.finishRemoval(token, removed: true, visibleIDs: conversationKeys), composer == nil {
                    listFocusRequest += 1
                }
            }
            if archiving { _ = await hub.archive(key, onRemoved: onRemoved) }
            else { _ = await hub.trash(key, onRemoved: onRemoved) }
            selection.finishRemoval(token, removed: false, visibleIDs: conversationKeys)
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
            reply: openConversation == nil ? nil : { [self] in respond(.reply) },
            replyAll: openConversation == nil ? nil : { [self] in respond(.replyAll) },
            forward: openConversation.map { $0.messages.allSatisfy(\.bodyLoaded) } == true ? { [self] in respond(.forward) } : nil,
            toggleRead: selected.map { item in { [self] in toggleRead(item) } },
            toggleFlag: selected.map { item in { [self] in toggleStar(item) } },
            selectionIsUnread: selected?.conversation.isUnread ?? false,
            selectionIsFlagged: selected?.conversation.isStarred ?? false
        )
    }
}
