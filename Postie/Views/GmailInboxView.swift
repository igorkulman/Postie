import SwiftUI

struct GmailInboxView: View {
    let hub: MailHub
    @State private var selectedID: ConversationKey?
    @State private var searchText = ""
    @State private var searchScope: SearchScope = .allMail
    @State private var searchRetry = 0
    @State private var selectionBeforeSearch: ConversationKey?
    @State private var refreshRequest = 0
    @State private var pageRequest = 0
    @State private var retryRequest = 0
    @State private var neighborAfterRemoval: ConversationKey?
    @State private var autoReadID: ConversationKey?
    @State private var composer: ComposeDraft?

    private var conversations: [MergedConversation] { hub.conversations }

    private struct SearchRequest: Hashable {
        let text: String
        let scope: SearchScope
        let retry: Int
    }

    private var mailboxSelection: Binding<Mailbox?> {
        Binding(
            get: { hub.mailbox },
            set: { mailbox in
                guard let mailbox, mailbox != hub.mailbox else { return }
                selectedID = nil
                searchText = ""
                selectionBeforeSearch = nil
                pageRequest = 0
                hub.changeMailbox(mailbox)
            }
        )
    }

    private var mailActions: MailActions {
        MailActions(
            currentMailbox: hub.mailbox,
            selectMailbox: { mailboxSelection.wrappedValue = $0 },
            newMessage: canCompose ? { composer = ComposeDraft(accountID: hub.defaultSendingAccount?.id) } : nil,
            refresh: hub.isLoadingMailbox || hub.mailbox == .outbox ? nil : { refreshRequest += 1 },
            archive: selectedID != nil && hub.canArchive(selectedID) ? { selectedID.map { remove($0, archiving: true) } } : nil,
            trash: selectedID != nil && hub.canTrash(selectedID) ? { selectedID.map { remove($0, archiving: false) } } : nil,
            reply: openConversation == nil ? nil : { respond(.reply) },
            replyAll: openConversation == nil ? nil : { respond(.replyAll) },
            forward: openConversation.map { $0.messages.allSatisfy(\.bodyLoaded) } == true ? { respond(.forward) } : nil,
            toggleRead: selected.map { conversation in { toggleRead(conversation) } },
            toggleFlag: selected.map { conversation in { toggleStar(conversation) } },
            selectionIsUnread: selected?.conversation.isUnread ?? false,
            selectionIsFlagged: selected?.conversation.isStarred ?? false
        )
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

    private var canCompose: Bool { !hub.sendingAccounts.isEmpty }

    /// The fully loaded conversation that Reply and Forward act on. Its account is the one that sends the response.
    private var openConversation: GmailConversation? {
        guard let selectedID, hub.sendingAccounts.contains(where: { $0.id == selectedID.accountID }),
              hub.mailbox != .outbox else { return nil }
        return hub.openConversation(for: selectedID)
    }

    private func respond(_ kind: ComposeKind) {
        guard let key = selectedID, let conversation = openConversation,
              let accountEmail = hub.email(for: key.accountID) else { return }
        let thread = conversation.presentation(includingBodies: true, mailbox: hub.mailbox)
        var draft = kind == .forward
            ? MailStore.forwardDraft(thread)
            : MailStore.replyDraft(to: thread, accountEmail: accountEmail, allRecipients: kind == .replyAll)
        draft.accountID = key.accountID
        draft.gmailThreadID = kind == .forward ? nil : key.threadID
        composer = draft
    }

    private var selected: MergedConversation? {
        guard let selectedID, hub.canModifyLabels(selectedID),
              let conversation = hub.conversation(for: selectedID) else { return nil }
        return MergedConversation(key: selectedID, conversation: conversation)
    }

    private func toggleRead(_ item: MergedConversation) {
        Task { await hub.setUnread(item.key, !item.conversation.isUnread) }
    }

    private func toggleStar(_ item: MergedConversation) {
        Task { await hub.setStarred(item.key, !item.conversation.isStarred) }
    }

    private func remove(_ key: ConversationKey, archiving: Bool) {
        let list = conversations
        // Select the neighbor that will take the row's place.
        let next = list.firstIndex { $0.key == key }.flatMap { index in
            list.indices.contains(index + 1) ? list[index + 1].key : (index > 0 ? list[index - 1].key : nil)
        }
        // Only move selection when the removed row is the open one.
        neighborAfterRemoval = selectedID == key ? next : selectedID
        Task {
            _ = archiving ? await hub.archive(key) : await hub.trash(key)
            neighborAfterRemoval = nil
        }
    }

    private struct MailboxRequest: Hashable {
        let mailbox: Mailbox
        let refresh: Int
        let accounts: [String]
    }

    private struct SelectionRequest: Hashable {
        let id: ConversationKey?
        let mailboxVersion: Int
        let retry: Int
    }

    var body: some View {
        NavigationSplitView {
            List(selection: mailboxSelection) {
                Section("Mailboxes") {
                    ForEach(Mailbox.allCases) { mailbox in
                        Label(mailbox.title, systemImage: mailbox.symbol)
                            .badge(mailbox == .inbox ? (hub.unreadInboxCount ?? 0) : 0)
                            .tag(mailbox)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } content: {
            messageList
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        }
        .navigationTitle(hub.mailbox.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar { MailToolbar(actions: mailActions) }
        .focusedSceneValue(\.mailActions, mailActions)
        .sheet(item: $composer) { draft in
            ComposerView(draft: draft, save: nil, send: hub.send, accounts: hub.sendingAccounts, isDemo: false)
        }
        // Also runs when an account is added, so its mail appears without choosing a folder again.
        .task(id: MailboxRequest(mailbox: hub.mailbox, refresh: refreshRequest, accounts: hub.sessions.map(\.id))) {
            await hub.restoreCachedMailbox()
            if selectedID == nil, !hub.isSearchActive { selectedID = conversations.first?.key }
            await hub.refresh()
        }
        // Searches as you type, after a short pause. A new keystroke cancels the pending request.
        .task(id: SearchRequest(text: searchText, scope: searchScope, retry: searchRetry)) {
            hub.setSearch(searchText, scope: searchScope)
            guard hub.isSearchActive else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await hub.performSearch()
        }
        .onChange(of: hub.isSearchActive) { _, active in
            if active {
                selectionBeforeSearch = selectedID
                selectedID = nil
            } else {
                selectedID = selectionBeforeSearch
                selectionBeforeSearch = nil
            }
        }
        .task(id: pageRequest) {
            if pageRequest > 0 { await hub.loadMore() }
        }
        .task(id: SelectionRequest(id: selectedID, mailboxVersion: hub.mailboxVersion, retry: retryRequest)) {
            await hub.select(selectedID)
            await markOpenedConversationRead()
        }
        .onChange(of: hub.mailboxVersion) { _, _ in
            if !conversations.contains(where: { $0.key == selectedID }) {
                selectedID = conversations.first { $0.key == neighborAfterRemoval }?.key
                    ?? (hub.isSearchActive ? nil : conversations.first?.key)
            }
        }
    }

    private var messageList: some View {
        VStack(spacing: 0) {
            ForEach(hub.notices) { notice in
                noticeView(notice)
                Divider()
            }
            if hub.isSearchActive {
                searchHeader
                Divider()
            }
            if hub.isSearchActive && hub.isSearching && hub.loadedCount == 0 {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if (hub.isLoadingMailbox || hub.isRestoringCache) && hub.loadedCount == 0 {
                ProgressView("Loading mail…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conversations.isEmpty {
                ContentUnavailableView {
                    Label(!hub.isSearchActive ? (hub.mailbox == .outbox ? String(localized: "Outbox is empty") : String(localized: "No conversations")) : String(localized: "No matching mail"),
                          systemImage: !hub.isSearchActive ? hub.mailbox.symbol : "magnifyingglass")
                } description: {
                    Text(!hub.isSearchActive
                         ? (hub.mailbox == .outbox
                            ? String(localized: "Messages are sent immediately, so nothing waits here.")
                            : String(localized: "Refresh to check for new mail."))
                         : String(localized: "Try other words, or use Gmail search such as from:name or has:attachment."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(conversations) { item in
                        MailThreadRow(thread: item.conversation.presentation(includingBodies: false, mailbox: hub.mailbox))
                            .tag(item.key)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading) {
                                if hub.canModifyLabels(item.key) {
                                    Button { toggleRead(item) } label: {
                                        Label(item.conversation.isUnread ? String(localized: "Read") : String(localized: "Unread"),
                                              systemImage: item.conversation.isUnread ? "envelope.open" : "envelope.badge")
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if hub.canTrash(item.key) {
                                    Button(role: .destructive) { remove(item.key, archiving: false) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                if hub.canArchive(item.key) {
                                    Button { remove(item.key, archiving: true) } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.indigo)
                                }
                            }
                            .onAppear {
                                // Load the next page as the end of the list scrolls into view.
                                if item.key == conversations.last?.key,
                                   hub.hasMorePages, !hub.isLoadingMailbox {
                                    pageRequest += 1
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if let key = selectedID, hub.canTrash(key) { remove(key, archiving: false) } }
                .contextMenu(forSelectionType: ConversationKey.self) { keys in
                    if let key = keys.first {
                        if hub.canModifyLabels(key), let conversation = hub.conversation(for: key) {
                            let item = MergedConversation(key: key, conversation: conversation)
                            Button(conversation.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                                   systemImage: conversation.isUnread ? "envelope.open" : "envelope.badge") { toggleRead(item) }
                            Button(conversation.isStarred ? String(localized: "Unflag") : String(localized: "Flag"),
                                   systemImage: conversation.isStarred ? "star.slash" : "star") { toggleStar(item) }
                            Divider()
                        }
                        if key == selectedID, let open = openConversation {
                            Button("Reply", systemImage: "arrowshape.turn.up.left") { respond(.reply) }
                            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { respond(.replyAll) }
                            if open.messages.allSatisfy(\.bodyLoaded) {
                                Button("Forward", systemImage: "arrowshape.turn.up.right") { respond(.forward) }
                            }
                            Divider()
                        }
                        if hub.canArchive(key) {
                            Button("Archive", systemImage: "archivebox") { remove(key, archiving: true) }
                        }
                        if hub.canTrash(key) {
                            Button("Move to Trash", systemImage: "trash", role: .destructive) { remove(key, archiving: false) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if hub.isLoadingMailbox {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Loading")
                }
                Text(hub.showingCachedMail
                     ? String(localized: "\(hub.loadedCount) cached", comment: "Conversation count in the list footer; the mail was loaded from the local cache")
                     : String(localized: "\(hub.loadedCount) loaded", comment: "Conversation count in the list footer; the mail was loaded from Gmail"))
                    .foregroundStyle(.secondary)
                    .help(hub.lastRefreshed.map { String(localized: "Last updated: \($0.formatted())") } ?? String(localized: "No folder refresh yet"))
                Spacer()
                if hub.hasMorePages {
                    Button("Load More") { pageRequest += 1 }
                        .disabled(hub.isLoadingMailbox)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 6) {
            Text("Search for “\(hub.searchQuery)”")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if hub.isSearching {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Searching")
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                scopeButton(hub.mailbox.title, .folder)
                scopeButton(String(localized: "All Mail"), .allMail)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search in")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A quiet, neutral pill: the scope is secondary to the results, so it doesn't use the accent color.
    private func scopeButton(_ title: String, _ scope: SearchScope) -> some View {
        Button { searchScope = scope } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(searchScope == scope ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                .foregroundStyle(searchScope == scope ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(searchScope == scope ? .isSelected : [])
    }

    @ViewBuilder
    private func noticeView(_ notice: HubNotice) -> some View {
        if notice.isError {
            GmailErrorBanner(message: notice.message) { refreshRequest += 1; searchRetry += 1 }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if case .reconnect(let accountID) = notice.fix {
                    Button("Reconnect Gmail") { hub.accounts.reconnect(accountID) }
                        .disabled(hub.accounts.isBusy)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let key = selectedID, let conversation = hub.openConversation(for: key) {
            VStack(spacing: 0) {
                if let error = hub.conversationError(key) {
                    GmailErrorBanner(message: error) { retryRequest += 1 }
                    Divider()
                }
                GmailConversationView(
                    conversation: conversation, mailbox: hub.mailbox,
                    canToggleStar: hub.canModifyLabels(key),
                    toggleStar: { toggleStar(MergedConversation(key: key, conversation: conversation)) }
                )
                    .id(key)
            }
        } else if hub.isLoadingConversation(selectedID) {
            ProgressView("Loading conversation…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = hub.conversationError(selectedID) {
            ContentUnavailableView {
                Label("Could Not Load Conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { retryRequest += 1 }
            }
        } else {
            ContentUnavailableView {
                Label("No Conversation Selected", systemImage: "envelope.open")
            } description: {
                Text("Select a conversation to read it.")
            }
        }
    }
}

private struct GmailErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Keep the projection's local UUIDs stable while expanding/collapsing messages.
private struct GmailConversationView: View {
    let conversation: GmailConversation
    let mailbox: Mailbox
    let canToggleStar: Bool
    let toggleStar: () -> Void
    @State private var thread: MailThread

    init(conversation: GmailConversation, mailbox: Mailbox, canToggleStar: Bool, toggleStar: @escaping () -> Void) {
        self.conversation = conversation
        self.mailbox = mailbox
        self.canToggleStar = canToggleStar
        self.toggleStar = toggleStar
        _thread = State(initialValue: conversation.presentation(includingBodies: true, mailbox: mailbox))
    }

    var body: some View {
        ThreadDetailView(thread: thread, canToggleStar: canToggleStar, toggleStar: toggleStar)
            .onChange(of: conversation) { _, updated in
                thread = updated.presentation(includingBodies: true, mailbox: mailbox)
            }
    }
}

extension GmailConversation {
    @MainActor
    func presentation(includingBodies: Bool, mailbox: Mailbox = .inbox) -> MailThread {
        MailThread(
            subject: subject,
            messages: messages.map {
                MailMessage(senderName: $0.senderName, senderEmail: $0.senderEmail,
                            recipient: $0.recipient, cc: $0.cc, date: $0.date,
                            body: includingBodies
                                ? ($0.bodyLoaded ? $0.body : $0.snippet + "\n\n" + String(localized: "This message body has not been downloaded. Connect to Gmail to read it."))
                                : $0.snippet,
                            htmlBody: includingBodies ? $0.htmlBody : nil)
            },
            mailbox: mailbox, isUnread: isUnread, isStarred: isStarred
        )
    }
}

private struct PreviewGmailAPI: GmailReading {
    let conversations: [Mailbox: [GmailConversation]]
    let failsBody: Bool
    nonisolated func unreadInboxCount() async throws -> Int {
        (conversations[.inbox] ?? []).reduce(0) { total, conversation in
            total + conversation.messages.filter { $0.labelIDs.contains("UNREAD") }.count
        }
    }
    nonisolated func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        let mail = conversations[mailbox] ?? []
        return GmailPage(conversations: mail, nextPageToken: !mail.isEmpty && pageToken == nil ? "preview-next" : nil)
    }
    nonisolated func conversation(id: String) async throws -> GmailConversation {
        if failsBody { throw GmailError.http(503) }
        guard let conversation = conversations.values.flatMap({ $0 }).first(where: { $0.id == id }) else { throw GmailError.http(404) }
        return conversation
    }
}

@MainActor
private func makeGmailPreviewHub(mailbox: Mailbox = .inbox, failsBody: Bool = false) -> MailHub {
    let conversations = Dictionary(grouping: SampleMail.threads(), by: \.mailbox).mapValues { threads in
        threads.map { thread in
            GmailConversation(id: thread.id.uuidString, subject: thread.subject, messages: thread.messages.map {
                GmailMessage(id: $0.id.uuidString, senderName: $0.senderName, senderEmail: $0.senderEmail,
                             recipient: $0.recipient, cc: $0.cc, date: $0.date, snippet: thread.preview,
                             body: $0.body, labelIDs: Set((thread.mailbox == .inbox ? ["INBOX"] : []) + (thread.isUnread ? ["UNREAD"] : []) + (thread.isStarred ? ["STARRED"] : [])))
            })
        }
    }
    let identity = GoogleIdentity(id: "preview", email: MailStore.accountEmail, name: MailStore.accountName)
    let credentials = GoogleCredentials(
        refreshToken: "", accessToken: "", expiresAt: .distantFuture, scopes: Set(GoogleOAuthClient.requiredScopes)
    )
    let accounts = AccountStore(vault: MemoryAccountVault([StoredAccount(identity: identity, credentials: credentials, addedAt: Date())]))
    accounts.restore()
    let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false) { _ in
        PreviewGmailAPI(conversations: conversations, failsBody: failsBody)
    }
    hub.changeMailbox(mailbox)
    return hub
}

private struct GmailPreview: View {
    @State private var hub: MailHub

    init(mailbox: Mailbox = .inbox, failsBody: Bool = false) {
        _hub = State(initialValue: makeGmailPreviewHub(mailbox: mailbox, failsBody: failsBody))
    }

    var body: some View {
        GmailInboxView(hub: hub)
            .task { await hub.reconcile() }
    }
}

#Preview("Gmail Reader") {
    GmailPreview()
        .frame(width: 1200, height: 820)
}

#Preview("Gmail Reader · Compact") {
    GmailPreview()
        .frame(width: 960, height: 640)
}

#Preview("Gmail Reader · Retry") {
    GmailPreview(failsBody: true)
        .frame(width: 960, height: 640)
}

#Preview("Gmail Sent · Dark") {
    GmailPreview(mailbox: .sent)
        .frame(width: 1200, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Gmail Outbox · Compact") {
    GmailPreview(mailbox: .outbox)
        .frame(width: 960, height: 640)
}
