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

    // Gmail access is read-only, so only navigation and refresh are available.
    private var mailActions: MailActions {
        MailActions(
            currentMailbox: reader.mailbox,
            selectMailbox: { mailboxSelection.wrappedValue = $0 },
            refresh: reader.isLoadingMailbox || reader.mailbox == .outbox ? nil : { refreshRequest += 1 }
        )
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
        }
        .onChange(of: reader.mailboxVersion) { _, _ in
            if !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations.first?.id }
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
                    }
                }
                .listStyle(.inset)
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
                GmailConversationView(conversation: conversation, mailbox: reader.mailbox)
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
                Text("Select a conversation to read it. Reading does not change its Gmail read status.")
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
    @State private var thread: MailThread

    init(conversation: GmailConversation, mailbox: Mailbox) {
        self.conversation = conversation
        self.mailbox = mailbox
        _thread = State(initialValue: conversation.presentation(includingBodies: true, mailbox: mailbox))
    }

    var body: some View {
        ThreadDetailView(thread: thread, canToggleStar: false, toggleStar: {})
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
