import SwiftUI

/// The middle column: notices, the search header, the conversation list and its footer.
struct ConversationListView: View {
    @Bindable var model: InboxModel
    var listIsFocused: FocusState<Bool>.Binding

    private var hub: MailHub { model.hub }

    private var listSelection: Binding<ConversationKey?> {
        Binding(get: { model.selectedID }, set: { model.updateFromList($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(hub.notices) { notice in
                NoticeView(notice: notice, canReconnect: !hub.accounts.isBusy, retry: model.retry) {
                    hub.accounts.reconnect($0)
                }
                Divider()
            }
            if hub.isSearchActive {
                SearchHeader(query: hub.searchQuery, folderTitle: hub.mailbox.title,
                             isSearching: hub.isSearching, scope: $model.searchScope)
                Divider()
            }
            // Keep the List (and its first responder) alive across loading and empty states.
            List(selection: listSelection) {
                ForEach(hub.conversations) { item in
                    MailThreadRow(thread: item.conversation.presentation(includingBodies: false, mailbox: hub.mailbox))
                        .tag(item.key)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            if hub.canModifyLabels(item.key) {
                                Button { model.toggleRead(item) } label: {
                                    Label(item.conversation.isUnread ? String(localized: "Read") : String(localized: "Unread"),
                                          systemImage: item.conversation.isUnread ? "envelope.open" : "envelope.badge")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if hub.canTrash(item.key) {
                                Button(role: .destructive) { model.remove(item.key, archiving: false) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            if hub.canArchive(item.key) {
                                Button { model.remove(item.key, archiving: true) } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.indigo)
                            }
                        }
                        .onAppear { model.conversationAppeared(item.key) }
                }
            }
            .listStyle(.inset)
            .focused(listIsFocused)
            .accessibilityIdentifier("conversationList")
            .onDeleteCommand {
                if let key = model.selectedID, hub.canTrash(key) { model.remove(key, archiving: false) }
            }
            .contextMenu(forSelectionType: ConversationKey.self) { keys in
                if let key = keys.first {
                    ConversationContextMenu(model: model, key: key)
                }
            }
            .overlay {
                if hub.conversations.isEmpty {
                    ListPlaceholder(isLoading: hub.isLoadingMailbox || hub.isRestoringCache,
                                    isSearching: hub.isSearchActive, mailbox: hub.mailbox)
                        .allowsHitTesting(false)
                }
            }
            Divider()
            ListFooter(isLoading: hub.isLoadingMailbox, loadedCount: hub.loadedCount,
                       showingCachedMail: hub.showingCachedMail, lastRefreshed: hub.lastRefreshed,
                       hasMorePages: hub.hasMorePages, loadMore: model.loadMore)
        }
    }
}

private struct ConversationContextMenu: View {
    let model: InboxModel
    let key: ConversationKey

    private var hub: MailHub { model.hub }

    var body: some View {
        if hub.canModifyLabels(key), let conversation = hub.conversation(for: key) {
            let item = MergedConversation(key: key, conversation: conversation)
            Button(conversation.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                   systemImage: conversation.isUnread ? "envelope.open" : "envelope.badge") { model.toggleRead(item) }
            Button(conversation.isStarred ? String(localized: "Unflag") : String(localized: "Flag"),
                   systemImage: conversation.isStarred ? "star.slash" : "star") { model.toggleStar(item) }
            Divider()
        }
        if key == model.selectedID, let open = model.openConversation {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { model.respond(.reply) }
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { model.respond(.replyAll) }
            if open.messages.allSatisfy(\.bodyLoaded) {
                Button("Forward", systemImage: "arrowshape.turn.up.right") { model.respond(.forward) }
            }
            Divider()
        }
        if hub.canArchive(key) {
            Button("Archive", systemImage: "archivebox") { model.remove(key, archiving: true) }
        }
        if hub.canTrash(key) {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.remove(key, archiving: false) }
        }
    }
}

private struct ListPlaceholder: View {
    let isLoading: Bool
    let isSearching: Bool
    let mailbox: Mailbox

    var body: some View {
        if isLoading, isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoading {
            ProgressView("Loading mail…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSearching {
            ContentUnavailableView {
                Label("No matching mail", systemImage: "magnifyingglass")
            } description: {
                Text("Try other words, or use Gmail search such as from:name or has:attachment.")
            }
        } else if mailbox == .outbox {
            ContentUnavailableView {
                Label("Outbox is empty", systemImage: mailbox.symbol)
            } description: {
                Text("Messages are sent immediately, so nothing waits here.")
            }
        } else {
            ContentUnavailableView {
                Label("No conversations", systemImage: mailbox.symbol)
            } description: {
                Text("Refresh to check for new mail.")
            }
        }
    }
}

private struct ListFooter: View {
    let isLoading: Bool
    let loadedCount: Int
    let showingCachedMail: Bool
    let lastRefreshed: Date?
    let hasMorePages: Bool
    let loadMore: () -> Void

    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading")
            }
            Text(showingCachedMail
                 ? String(localized: "\(loadedCount) cached", comment: "Conversation count in the list footer; the mail was loaded from the local cache")
                 : String(localized: "\(loadedCount) loaded", comment: "Conversation count in the list footer; the mail was loaded from Gmail"))
                .foregroundStyle(.secondary)
                .help(lastRefreshed.map { String(localized: "Last updated: \($0.formatted())") } ?? String(localized: "No folder refresh yet"))
            Spacer()
            if hasMorePages {
                Button("Load More", action: loadMore)
                    .disabled(isLoading)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SearchHeader: View {
    let query: String
    let folderTitle: String
    let isSearching: Bool
    @Binding var scope: SearchScope

    var body: some View {
        HStack(spacing: 6) {
            Text("Search for “\(query)”")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            if isSearching {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Searching")
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ScopeButton(title: folderTitle, scope: .folder, selection: $scope)
                ScopeButton(title: String(localized: "All Mail"), scope: .allMail, selection: $scope)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search in")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A quiet, neutral pill: the scope is secondary to the results, so it doesn't use the accent color.
private struct ScopeButton: View {
    let title: String
    let scope: SearchScope
    @Binding var selection: SearchScope

    private var isSelected: Bool { selection == scope }

    var body: some View {
        Button { selection = scope } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NoticeView: View {
    let notice: HubNotice
    let canReconnect: Bool
    let retry: () -> Void
    let reconnect: (String) -> Void

    var body: some View {
        if notice.isError {
            GmailErrorBanner(message: notice.message, retry: retry)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if case .reconnect(let accountID) = notice.fix {
                    Button("Reconnect Gmail") { reconnect(accountID) }
                        .disabled(!canReconnect)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GmailErrorBanner: View {
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
