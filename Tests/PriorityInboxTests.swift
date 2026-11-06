import Foundation
import Testing
@testable import Postie

/// A synced account whose first Inbox page leaves out an older starred thread.
private actor SyncedPriorityAPI: GmailSyncReading, GmailPriorityLoading {
    private let inbox: [GmailConversation]
    private let older: [GmailConversation]
    private(set) var priorityRequests: [Set<String>] = []

    init(inbox: [GmailConversation], older: [GmailConversation]) {
        self.inbox = inbox
        self.older = older
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: mailbox == .inbox ? inbox : [], nextPageToken: mailbox == .inbox ? "page 2" : nil)
    }
    func conversation(id: String) async throws -> GmailConversation { throw GmailError.http(404) }
    func unreadInboxCount() async throws -> Int { 0 }
    func currentHistoryID() async throws -> String { "100" }
    func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        GmailHistoryPage(history: [], nextPageToken: nil, historyId: "100")
    }
    func metadata(id: String) async throws -> GmailConversation? { (inbox + older).first { $0.id == id } }
    func priorityInboxThreads(excluding known: Set<String>) async throws -> [GmailConversation] {
        priorityRequests.append(known)
        return older.filter { !known.contains($0.id) }
    }
}

/// Lists one thread that has since left the Inbox.
private struct ArchivedThreadTransport: GmailTransport {
    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        let object: [String: Any] = request.url!.path.hasSuffix("/threads")
            ? ["threads": [["id": "gone"]]]
            : ["id": "gone", "messages": [["id": "m", "labelIds": ["STARRED"], "snippet": "s", "internalDate": "1000",
                                           "payload": ["mimeType": "text/plain", "headers": [[String: String]]()]]]]
        return GmailHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}

@Suite("Priority Inbox", .timeLimit(.minutes(1)))
@MainActor
struct PriorityInboxTests {
    private func key(_ id: String, account: String = "a") -> ConversationKey {
        ConversationKey(accountID: account, threadID: id)
    }

    private func until(_ condition: () async -> Bool) async throws {
        while await !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func important(_ id: String, at seconds: TimeInterval) -> GmailConversation {
        MailHubTests.conversation(id, at: seconds, unread: true).setting("IMPORTANT", to: true)
    }

    private func starred(_ id: String, at seconds: TimeInterval) -> GmailConversation {
        MailHubTests.conversation(id, at: seconds).setting("STARRED", to: true)
    }

    /// The thread IDs of each section's rows, in the order shown.
    private func sections(_ hub: MailHub) -> [InboxSection: [String]] {
        hub.list.sections.reduce(into: [:]) { $0[$1.section] = $1.conversations.map(\.key.threadID) }
    }

    /// An important unread thread, a starred one and two others, whose dates would mix them up.
    private func makeHub(usesPriorityInbox: Bool = true) async -> (HubAPI, MailHub) {
        let api = HubAPI([
            MailHubTests.conversation("newest", at: 400), starred("star", at: 300),
            MailHubTests.conversation("other", at: 200), important("vip", at: 100)
        ])
        let hub = await MailHubTests().makeHub(["a": api])
        hub.usesPriorityInbox = usesPriorityInbox
        return (api, hub)
    }

    // MARK: Sections

    @Test("A conversation goes in the first section it fits")
    func placement() {
        #expect(InboxSection(important("a", at: 1)) == .importantAndUnread)
        #expect(InboxSection(important("a", at: 1).setting("STARRED", to: true)) == .importantAndUnread)
        #expect(InboxSection(important("a", at: 1).setting("UNREAD", to: false)) == .everythingElse)
        #expect(InboxSection(important("a", at: 1).setting("UNREAD", to: false).setting("STARRED", to: true)) == .starred)
        #expect(InboxSection(starred("a", at: 1).setting("UNREAD", to: true)) == .starred)
        #expect(InboxSection(MailHubTests.conversation("a", at: 1, unread: true)) == .everythingElse)
    }

    @Test("The list and its keyboard order follow the sections, newest first within each")
    func order() async {
        let (_, hub) = await makeHub()
        #expect(hub.list.sections.map(\.section) == [.importantAndUnread, .starred, .everythingElse])
        #expect(sections(hub)[.everythingElse] == ["newest", "other"])
        #expect(hub.conversationKeys.map(\.threadID) == ["vip", "star", "newest", "other"])
    }

    @Test("Off, the list is one list, newest first, and turning it off goes back to that")
    func off() async {
        let (api, hub) = await makeHub(usesPriorityInbox: false)
        #expect(hub.list.sections.isEmpty)
        #expect(hub.conversationKeys.map(\.threadID) == ["newest", "star", "other", "vip"])
        #expect(await api.priorityRequests.isEmpty)

        hub.usesPriorityInbox = true
        #expect(!hub.list.sections.isEmpty)
        hub.usesPriorityInbox = false
        #expect(hub.list.sections.isEmpty)
        #expect(hub.conversationKeys.map(\.threadID) == ["newest", "star", "other", "vip"])
    }

    @Test("Only the Inbox is grouped: not other folders and not search results")
    func onlyTheInbox() async {
        let (_, hub) = await makeHub()
        hub.setSearch("vip", scope: .allMail)
        await hub.performSearch()
        #expect(hub.isSearchActive)
        #expect(hub.list.sections.isEmpty)
        hub.setSearch("", scope: .allMail)
        #expect(!hub.list.sections.isEmpty)

        hub.changeMailbox(.sent)
        await hub.refresh()
        #expect(hub.list.sections.isEmpty)
    }

    @Test("Every account's mail is grouped together")
    func severalAccounts() async {
        let hub = await MailHubTests().makeHub([
            "a": HubAPI([important("a1", at: 100), MailHubTests.conversation("a2", at: 400)]),
            "b": HubAPI([important("b1", at: 200), MailHubTests.conversation("b2", at: 300)])
        ])
        hub.usesPriorityInbox = true
        #expect(hub.conversationKeys == [key("b1", account: "b"), key("a1"), key("a2"), key("b2", account: "b")])
    }

    @Test("A section on its own has no heading, and can't stay collapsed without one")
    func loneSection() async {
        let hub = await MailHubTests().makeHub(["a": HubAPI([MailHubTests.conversation("a1", at: 100)])])
        hub.usesPriorityInbox = true
        hub.toggleSection(.everythingElse)
        #expect(hub.list.sections.isEmpty)
        #expect(hub.conversationKeys == [key("a1")])
    }

    // MARK: Collapsing

    @Test("A collapsed section hides its rows from the list and the keyboard, but its mail stays loaded")
    func collapse() async {
        let (_, hub) = await makeHub()
        hub.toggleSection(.starred)
        #expect(hub.conversationKeys.map(\.threadID) == ["vip", "newest", "other"])
        #expect(hub.list.sections.first { $0.section == .starred }?.count == 1)
        #expect(hub.list.sections.first { $0.section == .starred }?.conversations.isEmpty == true)
        #expect(hub.list[key("star")] != nil)
        #expect(hub.loadedCount == 4)

        hub.toggleSection(.starred)
        #expect(hub.conversationKeys.map(\.threadID) == ["vip", "star", "newest", "other"])
    }

    @Test("With every section collapsed the list has no rows but isn't empty, so it shows no placeholder")
    func everythingCollapsed() async {
        let (_, hub) = await makeHub()
        for section in InboxSection.allCases { hub.toggleSection(section) }
        #expect(hub.conversations.isEmpty)
        #expect(!hub.list.isEmpty)
    }

    @Test("Collapsing the section of the selected conversation closes it")
    func collapseSelected() async {
        let (_, hub) = await makeHub()
        let model = InboxModel(hub: hub)
        model.select(key("star"))
        hub.toggleSection(.starred)
        model.reconcileSelection()
        #expect(model.selectedID == nil)
    }

    @Test("A collapsed last section doesn't load more mail, since nothing in it can scroll into view")
    func collapsedEnd() async {
        let (_, hub) = await makeHub()
        #expect(!hub.list.endsCollapsed)
        hub.toggleSection(.everythingElse)
        #expect(hub.list.endsCollapsed)
    }

    // MARK: Keeping a conversation in place

    @Test("Reading a conversation keeps it in its section until another one is selected")
    func keptWhileSelected() async {
        let (_, hub) = await makeHub()
        let model = InboxModel(hub: hub)
        model.select(key("vip"))
        _ = await hub.setUnread(key("vip"), false)
        #expect(hub.conversation(for: key("vip"))?.isUnread == false)
        #expect(sections(hub)[.importantAndUnread] == ["vip"])
        #expect(model.selectedID == key("vip"))

        model.select(key("other"))
        #expect(sections(hub)[.importantAndUnread] == nil)
        #expect(sections(hub)[.everythingElse] == ["newest", "other", "vip"])
    }

    @Test("Unflagging keeps a conversation in Starred until it is deselected")
    func unflagged() async {
        let (_, hub) = await makeHub()
        let model = InboxModel(hub: hub)
        model.select(key("star"))
        _ = await hub.setStarred(key("star"), false)
        #expect(sections(hub)[.starred] == ["star"])

        model.select(nil)
        #expect(sections(hub)[.starred] == nil)
        #expect(sections(hub)[.everythingElse]?.contains("star") == true)
    }

    // MARK: Older threads

    @Test("Turning it on brings in older priority threads the first page left out, and every refresh keeps them")
    func olderThreads() async throws {
        let (api, hub) = await makeHub(usesPriorityInbox: false)
        await api.setOlderPriorityMail([starred("old", at: 10)])
        #expect(hub.list[key("old")] == nil)

        hub.usesPriorityInbox = true
        try await until { hub.list[key("old")] != nil }
        #expect(sections(hub)[.starred] == ["star", "old"])

        await hub.refresh()
        #expect(hub.conversationKeys.filter { $0 == key("old") }.count == 1)
        #expect(await api.priorityRequests.last == ["newest", "star", "other", "vip"])
    }

    @Test("Other folders don't ask for them")
    func olderThreadsOnlyInTheInbox() async {
        let (api, hub) = await makeHub()
        hub.changeMailbox(.sent)
        await hub.refresh()
        let requests = await api.priorityRequests.count
        await hub.refresh()
        #expect(await api.priorityRequests.count == requests)
    }

    @Test("Older threads are saved with the Inbox, keep its next page and aren't fetched again")
    func savedInTheCache() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let api = SyncedPriorityAPI(inbox: [MailHubTests.conversation("new", at: 100)], older: [starred("old", at: 10)])
        let reader = GmailReaderStore(api: api, cache: session)
        reader.loadsPriorityThreads = true

        await reader.refresh()
        #expect(reader.mailboxError == nil)
        #expect(reader.conversations.map(\.id).sorted() == ["new", "old"])
        #expect(reader.nextPageToken == "page 2")

        await reader.refresh()
        #expect(reader.conversations.map(\.id).sorted() == ["new", "old"])
        #expect(await api.priorityRequests.last == ["new", "old"])

        let restored = GmailReaderStore(api: api, cache: session)
        await restored.restoreCachedMailbox()
        #expect(restored.conversations.map(\.id).sorted() == ["new", "old"])
    }

    // MARK: Gmail requests

    @Test("Asks Gmail for both groups inside the Inbox and only reads the threads it doesn't know")
    func requests() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        let found = try await api.priorityInboxThreads(excluding: [])
        #expect(found.map(\.id) == ["a1"])

        let lists = await transport.requests.filter { $0.url!.path.hasSuffix("/threads") }
        let labels = lists.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .filter { $0.name == "labelIds" }.compactMap(\.value)
        }
        #expect(labels == [["INBOX", "IMPORTANT", "UNREAD"], ["INBOX", "STARRED"]])

        let known = FixtureTransport()
        let knownAPI = GmailAPI(transport: known) { "fixture-token" }
        #expect(try await knownAPI.priorityInboxThreads(excluding: ["a1", "deleted"]).isEmpty)
        #expect(await known.requests.count == 2)
    }

    @Test("A thread that has left the Inbox is left out")
    func notInTheInbox() async throws {
        let api = GmailAPI(transport: ArchivedThreadTransport()) { "fixture-token" }
        #expect(try await api.priorityInboxThreads(excluding: []).isEmpty)
    }

    // MARK: Settings

    @Test("The setting and the collapsed sections survive a restart")
    func remembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)"))
        let hub = MailHub(accounts: AccountStore(vault: MemoryAccountVault()), persistsMail: false, syncsInBackground: false, preferences: defaults)
        #expect(!hub.usesPriorityInbox)
        hub.usesPriorityInbox = true
        hub.toggleSection(.starred)

        let reopened = MailHub(accounts: AccountStore(vault: MemoryAccountVault()), persistsMail: false, syncsInBackground: false, preferences: defaults)
        #expect(reopened.usesPriorityInbox)
        #expect(reopened.collapsedSections == [.starred])
    }
}
