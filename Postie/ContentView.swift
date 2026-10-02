import SwiftUI

struct ContentView: View {
    var unreadCountChanged: (Int) -> Void = { _ in }
    @State private var store = MailStore()
    @State private var mailbox: Mailbox? = .inbox
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var composer: ComposeDraft?
    @State private var confirmsDraftDeletion = false

    private var currentMailbox: Mailbox { mailbox ?? .inbox }
    private var conversations: [MailThread] {
        store.conversations(in: currentMailbox, matching: searchText)
    }
    private var selectedThread: MailThread? {
        conversations.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } content: {
            messageList
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
        }
        .navigationTitle(currentMailbox.title)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar { MailToolbar(actions: mailActions) }
        .focusedSceneValue(\.mailActions, mailActions)
        .alert("Delete this draft?", isPresented: $confirmsDraftDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Draft", role: .destructive) { deleteSelection() }
        } message: {
            Text("This removes the saved demo draft. It cannot be undone.")
        }
        .sheet(item: $composer) { draft in
            ComposerView(draft: draft) { saved in
                store.saveDraft(saved)
                searchText = ""
                mailbox = .drafts
                selectedID = saved.id
            } send: { sent in
                if let id = store.sendDemo(sent) {
                    searchText = ""
                    mailbox = .sent
                    selectedID = id
                }
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = conversations.first?.id }
        }
        .onChange(of: store.unreadCount, initial: true) { _, count in
            unreadCountChanged(count)
        }
        .onChange(of: mailbox) { _, _ in
            searchText = ""
            selectedID = conversations.first?.id
        }
        .onChange(of: selectedID) { _, id in
            if let id { store.markRead(id) }
        }
        .onChange(of: searchText) { _, _ in
            if !conversations.contains(where: { $0.id == selectedID }) {
                selectedID = nil
            }
        }
    }

    private var mailActions: MailActions {
        var actions = MailActions(
            currentMailbox: currentMailbox,
            selectMailbox: { mailbox = $0 },
            newMessage: { composer = ComposeDraft() }
        )
        guard let thread = selectedThread else { return actions }
        if thread.mailbox == .inbox {
            actions.archive = { archiveSelection() }
        }
        if currentMailbox != .trash {
            actions.trash = { requestDeleteSelection() }
        }
        actions.toggleRead = { toggleRead(thread) }
        actions.toggleFlag = { store.toggleStar(thread.id) }
        actions.selectionIsUnread = thread.isUnread
        actions.selectionIsFlagged = thread.isStarred
        if thread.latestMessage != nil && currentMailbox != .drafts {
            actions.reply = { composeResponse(allRecipients: false) }
            actions.replyAll = { composeResponse(allRecipients: true) }
            actions.forward = { composer = store.forward(thread) }
        }
        return actions
    }

    private func composeResponse(allRecipients: Bool) {
        guard let thread = selectedThread else { return }
        composer = store.reply(to: thread, allRecipients: allRecipients)
    }

    private func archiveSelection() {
        if let thread = selectedThread { archive(thread.id) }
    }

    private func archive(_ id: UUID) {
        let index = conversations.firstIndex { $0.id == id } ?? 0
        store.archive(id)
        if selectedID == id { selectNeighbor(at: index) }
    }

    private func requestDeleteSelection() {
        guard selectedThread != nil else { return }
        if currentMailbox == .drafts {
            confirmsDraftDeletion = true
        } else {
            deleteSelection()
        }
    }

    private func deleteSelection() {
        if let thread = selectedThread { remove(thread.id) }
    }

    private func remove(_ id: UUID) {
        let index = conversations.firstIndex { $0.id == id } ?? 0
        if currentMailbox == .drafts {
            store.deleteDraft(id)
        } else {
            store.moveToTrash(id)
        }
        if selectedID == id { selectNeighbor(at: index) }
    }

    private func toggleRead(_ thread: MailThread) {
        if thread.isUnread { store.markRead(thread.id) } else { store.markUnread(thread.id) }
    }

    private func selectNeighbor(at index: Int) {
        let remaining = conversations
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    @ViewBuilder
    private func rowMenu(for thread: MailThread) -> some View {
        if currentMailbox != .drafts {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { composer = store.reply(to: thread) }
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                composer = store.reply(to: thread, allRecipients: true)
            }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { composer = store.forward(thread) }
            Divider()
            Button(thread.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                   systemImage: thread.isUnread ? "envelope.open" : "envelope.badge") { toggleRead(thread) }
            Button(thread.isStarred ? String(localized: "Unflag") : String(localized: "Flag"), systemImage: thread.isStarred ? "star.slash" : "star") {
                store.toggleStar(thread.id)
            }
            Divider()
        }
        if thread.mailbox == .inbox {
            Button("Archive", systemImage: "archivebox") { archive(thread.id) }
        }
        if currentMailbox == .drafts {
            Button("Delete Draft", systemImage: "trash", role: .destructive) {
                selectedID = thread.id
                confirmsDraftDeletion = true
            }
        } else if currentMailbox != .trash {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { remove(thread.id) }
        }
    }

    private func sidebarBadge(for item: Mailbox) -> Int {
        switch item {
        case .inbox: store.unreadCount
        case .drafts: store.drafts.count
        default: 0
        }
    }

    private var sidebar: some View {
        List(selection: $mailbox) {
            Section("Mailboxes") {
                ForEach(Mailbox.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(sidebarBadge(for: item))
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var messageList: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label(searchText.isEmpty ? String(localized: "Nothing here yet") : String(localized: "No matching mail"), systemImage: searchText.isEmpty ? currentMailbox.symbol : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? String(localized: "Your demo messages will appear here.") : String(localized: "Try a different name, subject, or phrase."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(conversations) { thread in
                        MailThreadRow(thread: thread)
                            .tag(thread.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading) {
                                Button { toggleRead(thread) } label: {
                                    Label(thread.isUnread ? String(localized: "Read") : String(localized: "Unread"),
                                          systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if currentMailbox != .trash {
                                    Button(role: .destructive) { remove(thread.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                if thread.mailbox == .inbox {
                                    Button { archive(thread.id) } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand(perform: mailActions.trash)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let thread = conversations.first(where: { $0.id == id }) {
                        rowMenu(for: thread)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let thread = selectedThread {
            if currentMailbox == .drafts {
                ContentUnavailableView {
                    Label(thread.subject, systemImage: "doc.text")
                } description: {
                    Text("This draft is saved for the current demo session only.")
                } actions: {
                    Button("Continue Writing") {
                        composer = store.drafts.first { $0.id == thread.id }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Delete Draft", role: .destructive, action: requestDeleteSelection)
                }
            } else {
                ThreadDetailView(thread: thread) {
                    store.toggleStar(thread.id)
                }
                .id(thread.id)
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

#Preview("Inbox") {
    ContentView()
        .frame(width: 1200, height: 820)
}

#Preview("Inbox · Dark") {
    ContentView()
        .frame(width: 1200, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Compact Window") {
    ContentView()
        .frame(width: 960, height: 640)
}
