import SwiftUI

/// The Gmail reader: folders, the conversation list and the open conversation.
/// What it does with them lives in `InboxModel`; the columns are their own views.
struct GmailInboxView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var model: InboxModel
    @FocusState private var listIsFocused: Bool
    @FocusState private var searchIsFocused: Bool

    init(hub: MailHub) {
        _model = State(initialValue: InboxModel(hub: hub))
    }

    private var hub: MailHub { model.hub }

    private var mailboxSelection: Binding<Mailbox?> {
        Binding(
            get: { hub.mailbox },
            set: { mailbox in
                if let mailbox { model.changeMailbox(mailbox) }
            }
        )
    }

    private struct MailboxRequest: Hashable {
        let mailbox: Mailbox
        let accounts: [String]
    }

    private struct SelectionRequest: Hashable {
        let id: ConversationKey?
        let mailboxVersion: Int
        let retry: Int
    }

    var body: some View {
        let actions = model.mailActions
        NavigationSplitView {
            MailboxSidebar(selection: mailboxSelection, badges: [.inbox: hub.unreadInboxCount ?? 0, .drafts: hub.draftCount])
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } content: {
            ConversationListView(model: model, listIsFocused: $listIsFocused)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            ConversationDetailView(model: model)
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        }
        .navigationTitle(hub.mailbox.title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .searchFocused($searchIsFocused)
        .toolbar { MailToolbar(actions: actions) }
        .focusedSceneValue(\.mailActions, actions)
        // Each message gets its own window, so the mailbox stays usable while writing.
        .onChange(of: model.composer) { _, draft in
            guard let draft else { return }
            openWindow(id: "composer", value: draft)
            model.composer = nil
        }
        // Also runs when an account is added, so its mail appears without choosing a folder again.
        .task(id: MailboxRequest(mailbox: hub.mailbox, accounts: hub.sessions.map(\.id))) {
            await hub.refresh()
        }
        // Searches as you type, after a short pause. A new keystroke cancels the pending request.
        .task(id: model.searchRequest) {
            guard model.applySearch() else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await hub.performSearch()
        }
        .task(id: SelectionRequest(id: model.selectedID, mailboxVersion: hub.mailboxVersion, retry: model.selectionRetry)) {
            await model.openSelection()
        }
        .onChange(of: model.conversationKeys, initial: true) {
            model.reconcileSelection()
        }
        .alert("Could not open the draft", isPresented: Binding(get: { model.draftError != nil }, set: { if !$0 { model.draftError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.draftError ?? "")
        }
        .onChange(of: model.listFocusRequest) {
            if !searchIsFocused, model.composer == nil { listIsFocused = true }
        }
    }
}
