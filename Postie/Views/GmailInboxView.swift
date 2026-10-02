import SwiftUI

struct GmailInboxView: View {
    @Bindable var reader: GmailReaderStore
    var accountNotice: String? = nil
    var reconnect: (() -> Void)? = nil
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var refreshRequest = 0
    @State private var pageRequest = 0
    @State private var retryRequest = 0
    @State private var neighborAfterRemoval: String?
    @State private var autoReadID: String?

    private var conversations: [GmailConversation] {
        reader.conversations.filter { $0.matches(searchText) }
    }

    private var mailboxSelection: Binding<Mailbox?> {
        Binding(
            get: { reader.mailbox },
            set: { mailbox in
                guard let mailbox, mailbox != reader.mailbox else { return }
                selectedID = nil
                searchText = ""
                pageRequest = 0
                reader.changeMailbox(mailbox)
            }
        )
    }

    // Reply, forward, and compose are not available yet; archive and trash are.
    private var mailActions: MailActions {
        MailActions(
            currentMailbox: reader.mailbox,
            selectMailbox: { mailboxSelection.wrappedValue = $0 },
            refresh: reader.isLoadingMailbox || reader.mailbox == .outbox ? nil : { refreshRequest += 1 },
            archive: selectedID != nil && reader.canArchive ? { selectedID.map { remove($0, archiving: true) } } : nil,
            trash: selectedID != nil && reader.canTrash ? { selectedID.map { remove($0, archiving: false) } } : nil,
            toggleRead: selected.map { conversation in { toggleRead(conversation) } },
            toggleFlag: selected.map { conversation in { toggleStar(conversation) } },
            selectionIsUnread: selected?.isUnread ?? false,
            selectionIsFlagged: selected?.isStarred ?? false
        )
    }

    /// Marks the open conversation read after it has stayed open briefly, so skimming past mail doesn't change it.
    private func markOpenedConversationRead() async {
        guard let id = selectedID, reader.canModifyLabels, autoReadID != id else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, selectedID == id, reader.selectedConversation?.id == id,
              reader.selectedConversation?.isUnread == true else { return }
        autoReadID = id
        // Unstructured: the follow-up refresh must not be cancelled by a selection change.
        Task { await reader.setUnread(id, false) }
    }

    private var selected: GmailConversation? {
        guard reader.canModifyLabels, let selectedID else { return nil }
        return reader.conversations.first { $0.id == selectedID }
    }

    private func toggleRead(_ conversation: GmailConversation) {
        Task { await reader.setUnread(conversation.id, !conversation.isUnread) }
    }

    private func toggleStar(_ conversation: GmailConversation) {
        Task { await reader.setStarred(conversation.id, !conversation.isStarred) }
    }

    private func remove(_ id: String, archiving: Bool) {
        let list = conversations
        // Select the neighbor that will take the row's place.
        let next = list.firstIndex { $0.id == id }.flatMap { index in
            list.indices.contains(index + 1) ? list[index + 1].id : (index > 0 ? list[index - 1].id : nil)
        }
        // Only move selection when the removed row is the open one.
        neighborAfterRemoval = selectedID == id ? next : selectedID
        Task {
            _ = archiving ? await reader.archive(id) : await reader.trash(id)
            neighborAfterRemoval = nil
        }
    }

    private struct MailboxRequest: Hashable {
        let mailbox: Mailbox
        let refresh: Int
    }

    private struct SelectionRequest: Hashable {
        let id: String?
        let mailboxVersion: Int
        let retry: Int
    }

    var body: some View {
        NavigationSplitView {
            List(selection: mailboxSelection) {
                Section("Mailboxes") {
                    ForEach(Mailbox.allCases) { mailbox in
                        Label(mailbox.rawValue, systemImage: mailbox.symbol)
                            .badge(mailbox == .inbox ? (reader.unreadInboxCount ?? 0) : 0)
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
        .navigationTitle(reader.mailbox.rawValue)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar { MailToolbar(actions: mailActions) }
        .focusedSceneValue(\.mailActions, mailActions)
        .task(id: MailboxRequest(mailbox: reader.mailbox, refresh: refreshRequest)) {
            await reader.restoreCachedMailbox()
            if selectedID == nil { selectedID = conversations.first?.id }
            await reader.refresh()
        }
        .task(id: pageRequest) {
            if pageRequest > 0 { await reader.loadMore() }
        }
        .task(id: SelectionRequest(id: selectedID, mailboxVersion: reader.mailboxVersion, retry: retryRequest)) {
            await reader.select(selectedID)
            await markOpenedConversationRead()
        }
        .onChange(of: reader.mailboxVersion) { _, _ in
            if !conversations.contains(where: { $0.id == selectedID }) {
                selectedID = conversations.first { $0.id == neighborAfterRemoval }?.id ?? conversations.first?.id
            }
        }
        .onChange(of: searchText) { _, _ in
            if !conversations.contains(where: { $0.id == selectedID }) { selectedID = nil }
        }
    }

    private var messageList: some View {
        VStack(spacing: 0) {
            if let notice = reader.cacheError ?? accountNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notice)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let reconnect { Button("Reconnect Gmail", action: reconnect) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let error = reader.mailboxError {
                GmailErrorBanner(message: error) { refreshRequest += 1 }
                Divider()
            }
            if (reader.isLoadingMailbox || reader.isRestoringCache) && reader.conversations.isEmpty {
                ProgressView("Loading \(reader.mailbox.rawValue)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if conversations.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? (reader.mailbox == .outbox ? "Outbox is empty" : "No conversations") : "No matching mail",
                          systemImage: searchText.isEmpty ? reader.mailbox.symbol : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty
                         ? (reader.mailbox == .outbox ? "Messages waiting to be sent will appear here. Sending is not available yet." : "Refresh to check your \(reader.mailbox.rawValue).")
                         : "Search covers loaded conversations in this folder only. Load more or try another phrase.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(conversations) { conversation in
                        MailThreadRow(thread: conversation.presentation(includingBodies: false, mailbox: reader.mailbox))
                            .tag(conversation.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading) {
                                if reader.canModifyLabels {
                                    Button { toggleRead(conversation) } label: {
                                        Label(conversation.isUnread ? "Read" : "Unread",
                                              systemImage: conversation.isUnread ? "envelope.open" : "envelope.badge")
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if reader.canTrash {
                                    Button(role: .destructive) { remove(conversation.id, archiving: false) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                if reader.canArchive {
                                    Button { remove(conversation.id, archiving: true) } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.indigo)
                                }
                            }
                            .onAppear {
                                // Load the next page as the end of the list scrolls into view.
                                if conversation.id == conversations.last?.id, searchText.isEmpty,
                                   reader.nextPageToken != nil, !reader.isLoadingMailbox {
                                    pageRequest += 1
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if reader.canTrash, let id = selectedID { remove(id, archiving: false) } }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        if reader.canModifyLabels, let conversation = reader.conversations.first(where: { $0.id == id }) {
                            Button(conversation.isUnread ? "Mark as Read" : "Mark as Unread",
                                   systemImage: conversation.isUnread ? "envelope.open" : "envelope.badge") { toggleRead(conversation) }
                            Button(conversation.isStarred ? "Unflag" : "Flag",
                                   systemImage: conversation.isStarred ? "star.slash" : "star") { toggleStar(conversation) }
                            Divider()
                        }
                        if reader.canArchive {
                            Button("Archive", systemImage: "archivebox") { remove(id, archiving: true) }
                        }
                        if reader.canTrash {
                            Button("Move to Trash", systemImage: "trash", role: .destructive) { remove(id, archiving: false) }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if reader.isLoadingMailbox { ProgressView().controlSize(.small) }
                Text("\(reader.conversations.count) \(reader.showingCachedMail ? "cached" : "loaded")")
                    .foregroundStyle(.secondary)
                    .help(reader.lastRefreshed.map { "Last updated: " + $0.formatted() } ?? "No folder refresh yet")
                Spacer()
                if reader.nextPageToken != nil {
                    Button("Load More") { pageRequest += 1 }
                        .disabled(reader.isLoadingMailbox)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let conversation = reader.selectedConversation, conversation.id == selectedID {
            VStack(spacing: 0) {
                if let error = reader.conversationError {
                    GmailErrorBanner(message: error) { retryRequest += 1 }
                    Divider()
                }
                GmailConversationView(
                    conversation: conversation, mailbox: reader.mailbox,
                    canToggleStar: reader.canModifyLabels, toggleStar: { toggleStar(conversation) }
                )
                    .id(conversation.id)
            }
        } else if reader.isLoadingConversation {
            ProgressView("Loading conversation…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = reader.conversationError {
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
                                ? ($0.bodyLoaded ? $0.body : $0.snippet + "\n\nThis message body has not been downloaded. Connect to Gmail to read it.")
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
private func makeGmailPreviewStore(mailbox: Mailbox = .inbox, failsBody: Bool = false) -> GmailReaderStore {
    let conversations = Dictionary(grouping: SampleMail.threads(), by: \.mailbox).mapValues { threads in
        threads.map { thread in
            GmailConversation(id: thread.id.uuidString, subject: thread.subject, messages: thread.messages.map {
                GmailMessage(id: $0.id.uuidString, senderName: $0.senderName, senderEmail: $0.senderEmail,
                             recipient: $0.recipient, cc: $0.cc, date: $0.date, snippet: thread.preview,
                             body: $0.body, labelIDs: Set((thread.mailbox == .inbox ? ["INBOX"] : []) + (thread.isUnread ? ["UNREAD"] : []) + (thread.isStarred ? ["STARRED"] : [])))
            })
        }
    }
    return GmailReaderStore(api: PreviewGmailAPI(conversations: conversations, failsBody: failsBody), mailbox: mailbox)
}

#Preview("Gmail Reader") {
    GmailInboxView(reader: makeGmailPreviewStore())
        .frame(width: 1200, height: 820)
}

#Preview("Gmail Reader · Compact") {
    GmailInboxView(reader: makeGmailPreviewStore())
        .frame(width: 960, height: 640)
}

#Preview("Gmail Reader · Retry") {
    GmailInboxView(reader: makeGmailPreviewStore(failsBody: true))
        .frame(width: 960, height: 640)
}

#Preview("Gmail Sent · Dark") {
    GmailInboxView(reader: makeGmailPreviewStore(mailbox: .sent))
        .frame(width: 1200, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Gmail Outbox · Compact") {
    GmailInboxView(reader: makeGmailPreviewStore(mailbox: .outbox))
        .frame(width: 960, height: 640)
}
