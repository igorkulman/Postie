import Foundation
import Observation

@MainActor
@Observable
final class GmailReaderStore {
    private(set) var mailbox: Mailbox
    private(set) var conversations: [GmailConversation] = []
    private(set) var nextPageToken: String?
    private(set) var isLoadingMailbox = false
    private(set) var mailboxError: String?
    private(set) var mailboxVersion = 0
    private(set) var selectedConversation: GmailConversation?
    private(set) var isLoadingConversation = false
    private(set) var conversationError: String?

    @ObservationIgnored private let api: any GmailReading
    @ObservationIgnored private var bodies: [String: GmailConversation] = [:]
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var selection = UUID()

    init(api: any GmailReading, mailbox: Mailbox = .inbox) {
        self.api = api
        self.mailbox = mailbox
    }

    func changeMailbox(_ mailbox: Mailbox) {
        guard self.mailbox != mailbox else { return }
        reset()
        self.mailbox = mailbox
    }

    func reset() {
        mailbox = .inbox
        session = UUID()
        selection = UUID()
        conversations = []
        bodies = [:]
        nextPageToken = nil
        isLoadingMailbox = false
        isLoadingConversation = false
        mailboxError = nil
        conversationError = nil
        selectedConversation = nil
        mailboxVersion += 1
    }

    func refresh() async { await loadPage(refreshing: true) }
    func loadMore() async {
        guard nextPageToken != nil else { return }
        await loadPage(refreshing: false)
    }

    private func loadPage(refreshing: Bool) async {
        guard !isLoadingMailbox, mailbox != .outbox else { return }
        let currentSession = session
        let currentMailbox = mailbox
        let pageToken = refreshing ? nil : nextPageToken
        isLoadingMailbox = true
        mailboxError = nil
        defer { if session == currentSession { isLoadingMailbox = false } }
        do {
            let page = try await api.mailbox(currentMailbox, pageToken: pageToken)
            try Task.checkCancellation()
            guard session == currentSession else { return }
            if refreshing {
                conversations = page.conversations
                bodies = [:]
                mailboxVersion += 1
            } else {
                let existing = Set(conversations.map(\.id))
                conversations += page.conversations.filter { !existing.contains($0.id) }
            }
            // Prevent a bad/repeated continuation token from trapping Load More in a loop.
            nextPageToken = page.nextPageToken == pageToken ? nil : page.nextPageToken
        } catch {
            guard session == currentSession, !Task.isCancelled, !(error is CancellationError) else { return }
            // A failed refresh keeps the previously loaded messages and continuation token.
            mailboxError = error.localizedDescription
        }
    }

    func select(_ id: String?) async {
        selection = UUID()
        let currentSelection = selection
        let currentSession = session
        selectedConversation = nil
        conversationError = nil
        isLoadingConversation = false
        guard let id else { return }
        if let cached = bodies[id] {
            selectedConversation = cached
            return
        }
        isLoadingConversation = true
        defer { if selection == currentSelection { isLoadingConversation = false } }
        do {
            let conversation = try await api.conversation(id: id)
            try Task.checkCancellation()
            guard session == currentSession, selection == currentSelection else { return }
            bodies[id] = conversation
            if let index = conversations.firstIndex(where: { $0.id == id }) {
                conversations[index] = conversation
            }
            selectedConversation = conversation
        } catch {
            guard session == currentSession, selection == currentSelection, !Task.isCancelled, !(error is CancellationError) else { return }
            conversationError = error.localizedDescription
        }
    }
}
