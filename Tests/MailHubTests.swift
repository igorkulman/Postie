import Foundation
import Testing
@testable import Postie

/// A Gmail account that serves fixed mail and records what is done to it.
actor HubAPI: GmailSearching, GmailMutating, GmailSending {
    private(set) var mail: [GmailConversation]
    private(set) var archived: [String] = []
    private(set) var trashed: [String] = []
    private(set) var sent: [OutgoingMessage] = []
    private(set) var searches: [(query: String, mailbox: Mailbox?)] = []

    init(_ mail: [GmailConversation]) { self.mail = mail }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: mailbox == .inbox ? mail : [], nextPageToken: nil)
    }
    func conversation(id: String) async throws -> GmailConversation {
        guard let found = mail.first(where: { $0.id == id }) else { throw GmailError.http(404) }
        return found
    }
    func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        searches.append((query, mailbox))
        return GmailPage(conversations: mail.filter { $0.subject.localizedCaseInsensitiveContains(query) }, nextPageToken: nil)
    }
    func unreadInboxCount() async throws -> Int { mail.filter(\.isUnread).count }
    func archive(threadID: String) async throws { archived.append(threadID); mail.removeAll { $0.id == threadID } }
    func trash(threadID: String) async throws { trashed.append(threadID); mail.removeAll { $0.id == threadID } }
    func setLabel(_ label: String, on: Bool, threadID: String) async throws {}
    func send(_ message: OutgoingMessage) async throws { sent.append(message) }
}

@Suite("Merged mailbox", .timeLimit(.minutes(1)))
@MainActor
struct MailHubTests {
    static func conversation(_ id: String, at seconds: TimeInterval, unread: Bool = false) -> GmailConversation {
        GmailConversation(id: id, subject: "Subject \(id)", messages: [
            GmailMessage(id: id + "-m", senderName: "Sender", senderEmail: "s@example.com", recipient: "me@example.com",
                         cc: "", date: Date(timeIntervalSince1970: seconds), snippet: "snippet", body: "body",
                         labelIDs: unread ? ["INBOX", "UNREAD"] : ["INBOX"])
        ])
    }

    func makeHub(_ apis: [String: HubAPI], order: [String]? = nil) async -> MailHub {
        let ids = order ?? apis.keys.sorted()
        let stored = ids.enumerated().map { index, id in
            StoredAccount(
                identity: GoogleIdentity(id: id, email: "\(id)@example.com", name: nil),
                credentials: GoogleCredentials(refreshToken: "r", accessToken: "t", expiresAt: .distantFuture,
                                               scopes: Set(GoogleOAuthClient.requiredScopes)),
                addedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let accounts = AccountStore(
            vault: MemoryAccountVault(stored), oauth: GoogleOAuthClient(clientID: OAuthFixtures.clientID),
            defaults: UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)")!
        )
        accounts.restore()
        let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false) { apis[$0]! }
        await hub.reconcile()
        await hub.refresh()
        return hub
    }

    @Test("Every account's folder is merged into one list, newest first")
    func merge() async {
        let hub = await makeHub([
            "a": HubAPI([Self.conversation("a1", at: 100), Self.conversation("a2", at: 300, unread: true)]),
            "b": HubAPI([Self.conversation("b1", at: 200, unread: true)])
        ])
        #expect(hub.conversations.map(\.key) == [
            ConversationKey(accountID: "a", threadID: "a2"),
            ConversationKey(accountID: "b", threadID: "b1"),
            ConversationKey(accountID: "a", threadID: "a1")
        ])
        #expect(hub.unreadInboxCount == 2)
        #expect(hub.loadedCount == 3)
    }

    @Test("Identical thread IDs in two accounts stay separate conversations")
    func sameThreadID() async {
        let hub = await makeHub([
            "a": HubAPI([Self.conversation("t1", at: 100)]),
            "b": HubAPI([Self.conversation("t1", at: 200)])
        ])
        #expect(hub.conversations.count == 2)
        #expect(Set(hub.conversations.map(\.key)).count == 2)
    }

    @Test("Archive and trash go to the account that owns the conversation")
    func routing() async {
        let a = HubAPI([Self.conversation("a1", at: 100)])
        let b = HubAPI([Self.conversation("b1", at: 200)])
        let hub = await makeHub(["a": a, "b": b])
        #expect(await hub.archive(ConversationKey(accountID: "b", threadID: "b1")))
        #expect(await hub.trash(ConversationKey(accountID: "a", threadID: "a1")))
        let (aArchived, aTrashed) = (await a.archived, await a.trashed)
        let (bArchived, bTrashed) = (await b.archived, await b.trashed)
        #expect(aArchived.isEmpty && aTrashed == ["a1"])
        #expect(bArchived == ["b1"] && bTrashed.isEmpty)
        #expect(hub.conversations.isEmpty)
    }

    @Test("Opening a conversation closes the one another account had open")
    func selection() async {
        let hub = await makeHub([
            "a": HubAPI([Self.conversation("a1", at: 100)]),
            "b": HubAPI([Self.conversation("b1", at: 200)])
        ])
        let first = ConversationKey(accountID: "a", threadID: "a1")
        let second = ConversationKey(accountID: "b", threadID: "b1")
        await hub.select(first)
        #expect(hub.openConversation(for: first)?.id == "a1")
        await hub.select(second)
        #expect(hub.openConversation(for: first) == nil)
        #expect(hub.openConversation(for: second)?.id == "b1")
    }

    @Test("A message is sent from its draft's account, else from the default account")
    func sending() async throws {
        let a = HubAPI([])
        let b = HubAPI([])
        let hub = await makeHub(["a": a, "b": b], order: ["a", "b"])
        var draft = ComposeDraft(recipient: "x@example.com", subject: "Hi", body: "Hello")
        try await hub.send(draft)
        draft.accountID = "b"
        try await hub.send(draft)
        #expect(await a.sent.map(\.from) == ["a@example.com"])
        #expect(await b.sent.map(\.from) == ["b@example.com"])
        hub.accounts.setDefault("b")
        #expect(hub.defaultSendingAccount?.id == "b")
        #expect(hub.sendingAccounts.map(\.id) == ["a", "b"])
    }

    @Test("Removing an account drops its mail from the merged list")
    func removal() async {
        let hub = await makeHub([
            "a": HubAPI([Self.conversation("a1", at: 100)]),
            "b": HubAPI([Self.conversation("b1", at: 200)])
        ])
        await hub.removeAccount("a")
        #expect(hub.sessions.map(\.id) == ["b"])
        #expect(hub.conversations.map(\.key.accountID) == ["b"])
        #expect(hub.accounts.accounts.map(\.id) == ["b"])
    }

    @Test("Search merges results from every account without touching the folder list")
    func search() async {
        let a = HubAPI([Self.conversation("alza1", at: 100), Self.conversation("other", at: 300)])
        let b = HubAPI([Self.conversation("alza2", at: 200)])
        let hub = await makeHub(["a": a, "b": b])
        hub.setSearch("  alza ", scope: .allMail)
        #expect(hub.isSearchActive)
        await hub.performSearch()
        #expect(hub.conversations.map(\.key) == [
            ConversationKey(accountID: "b", threadID: "alza2"),
            ConversationKey(accountID: "a", threadID: "alza1")
        ])
        #expect(!hub.isSearching)
        #expect(await a.searches.map(\.query) == ["alza"])
        #expect(await a.searches.first?.mailbox == nil)
        hub.setSearch("", scope: .allMail)
        #expect(!hub.isSearchActive)
        #expect(hub.conversations.count == 3)
    }

    @Test("Searching this folder limits the query to the current mailbox")
    func searchFolder() async {
        let a = HubAPI([Self.conversation("alza1", at: 100)])
        let hub = await makeHub(["a": a])
        hub.setSearch("alza", scope: .folder)
        await hub.performSearch()
        #expect(await a.searches.first?.mailbox == .inbox)
    }

    @Test("Archiving a search result removes it from the results")
    func archiveFromSearch() async {
        let a = HubAPI([Self.conversation("alza1", at: 100), Self.conversation("alza2", at: 200)])
        let hub = await makeHub(["a": a])
        hub.setSearch("alza", scope: .allMail)
        await hub.performSearch()
        let key = ConversationKey(accountID: "a", threadID: "alza1")
        #expect(hub.canArchive(key))
        #expect(await hub.archive(key))
        #expect(hub.conversations.map(\.key.threadID) == ["alza2"])
    }
}
