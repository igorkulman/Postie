import SwiftUI

struct ContentView: View {
    var unreadCountChanged: (Int) -> Void = { _ in }
    @State private var store = MailStore()
    @State private var mailbox: Mailbox? = .inbox
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var composer: ComposeDraft?
    @State private var confirmsDraftDeletion = false
    @State private var readerWidth: CGFloat = 620

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
                .toolbar(removing: .sidebarToggle)
        } content: {
            messageList
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 420, ideal: 620)
                // Keep the window-toolbar actions aligned with the reader as dividers move.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    readerWidth = width
                }
        }
        .navigationTitle(currentMailbox.rawValue)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    composer = ComposeDraft()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New message (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                MailActionToolbar(
                    searchText: $searchText,
                    canArchive: selectedThread?.mailbox == .inbox,
                    canDelete: selectedThread != nil && currentMailbox != .trash,
                    canRespond: selectedThread?.latestMessage != nil && currentMailbox != .drafts,
                    deletingDraft: currentMailbox == .drafts,
                    archive: archiveSelection,
                    delete: requestDeleteSelection,
                    reply: { composeResponse(allRecipients: false) },
                    replyAll: { composeResponse(allRecipients: true) },
                    forward: {
                        if let thread = selectedThread { composer = store.forward(thread) }
                    }
                )
                .frame(width: max(360, readerWidth - 24))
            }
            .sharedBackgroundVisibility(.hidden)
        }
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

    private func composeResponse(allRecipients: Bool) {
        guard let thread = selectedThread else { return }
        composer = store.reply(to: thread, allRecipients: allRecipients)
    }

    private func archiveSelection() {
        guard let thread = selectedThread else { return }
        let index = conversations.firstIndex { $0.id == thread.id } ?? 0
        store.archive(thread.id)
        selectNeighbor(at: index)
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
        guard let thread = selectedThread else { return }
        let index = conversations.firstIndex { $0.id == thread.id } ?? 0
        if currentMailbox == .drafts {
            store.deleteDraft(thread.id)
        } else {
            store.moveToTrash(thread.id)
        }
        selectNeighbor(at: index)
    }

    private func selectNeighbor(at index: Int) {
        let remaining = conversations
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    private var sidebar: some View {
        List(selection: $mailbox) {
            Section("Mailboxes") {
                ForEach(Mailbox.allCases) { item in
                    HStack {
                        Label(item.rawValue, systemImage: item.symbol)
                        Spacer()
                        if item == .inbox && store.unreadCount > 0 {
                            Text("\(store.unreadCount)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if item == .drafts && !store.drafts.isEmpty {
                            Text("\(store.drafts.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
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
                    Label(searchText.isEmpty ? "Nothing here yet" : "No matching mail", systemImage: searchText.isEmpty ? currentMailbox.symbol : "magnifyingglass")
                } description: {
                    Text(searchText.isEmpty ? "Your demo messages will appear here." : "Try a different name, subject, or phrase.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(conversations) { thread in
                        MailThreadRow(thread: thread)
                            .tag(thread.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
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
