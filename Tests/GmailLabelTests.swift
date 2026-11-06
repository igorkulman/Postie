import Foundation
import Testing
@testable import Postie

@Suite("Gmail labels", .timeLimit(.minutes(1)))
struct GmailLabelTests {
    private func conversation(_ labels: Set<String>...) -> GmailConversation {
        GmailConversation(id: "thread", subject: "Subject", messages: labels.enumerated().map { index, labels in
            GmailMessage(id: "message-\(index)", senderName: "Sender", senderEmail: "sender@example.com", recipient: "alex@example.com",
                         cc: "", date: Date(timeIntervalSince1970: Double(index)), snippet: "", body: "", labelIDs: labels)
        })
    }

    @Test("The folder comes first, then the person's own labels by name, from every message")
    func visibleLabels() {
        let names = ["Label_1": "Safety", "Label_2": "Follow up", "Label_3": "Not on this conversation"]
        let labels = conversation(["INBOX", "Label_1"], ["Label_2"]).visibleLabels(named: names)
        #expect(labels == [Mailbox.inbox.title, "Follow up", "Safety"])
    }

    @Test("States, categories and other system labels are not shown")
    func hiddenLabels() {
        let labels = conversation(["UNREAD", "STARRED", "IMPORTANT", "SENT", "DRAFT", "OUTBOX", "CATEGORY_UPDATES"])
        #expect(labels.visibleLabels(named: [:]).isEmpty)
    }

    @Test("A label whose name is not known yet is left out rather than shown as an ID")
    func unknownLabel() {
        #expect(conversation(["TRASH", "Label_9"]).visibleLabels(named: [:]) == [Mailbox.trash.title])
        #expect(conversation(["SPAM"]).visibleLabels(named: [:]) == [Mailbox.junk.title])
    }

    @Test("Only labels the person created are read from Gmail, with where Gmail lists them")
    func listRequest() async throws {
        let transport = LabelTransport(body: #"""
        {"labels":[{"id":"INBOX","name":"INBOX","type":"system"},{"id":"Label_1","name":"Safety","type":"user"},
        {"id":"Label_2","name":"Work/Clients","type":"user","labelListVisibility":"labelHide"},
        {"id":"Label_3","name":"Quiet","type":"user","labelListVisibility":"labelShowIfUnread"}]}
        """#)
        let api = GmailAPI(transport: transport) { "fixture-token" }
        #expect(try await api.userLabels() == [
            GmailLabel(id: "Label_1", name: "Safety"),
            GmailLabel(id: "Label_2", name: "Work/Clients", visibility: .hide),
            GmailLabel(id: "Label_3", name: "Quiet", visibility: .showIfUnread)
        ])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/gmail/v1/users/me/labels")
    }

    @Test("A label's unread conversations are asked for by its ID, and none is left out of the answer")
    func unreadRequest() async throws {
        let some = LabelTransport(body: #"{"id":"Label_1","threadsUnread":14}"#)
        #expect(try await GmailAPI(transport: some) { "fixture-token" }.unreadThreads(inLabel: "Label_1") == 14)
        #expect(await some.requests.first?.url?.path == "/gmail/v1/users/me/labels/Label_1")

        let none = LabelTransport(body: #"{"id":"Label_1"}"#)
        #expect(try await GmailAPI(transport: none) { "fixture-token" }.unreadThreads(inLabel: "Label_1") == 0)
    }

    @Test("Opening a label asks Gmail for its threads")
    func folderRequest() async throws {
        let transport = LabelTransport(body: #"{"threads":[]}"#)
        _ = try await GmailAPI(transport: transport) { "fixture-token" }.mailbox(.label("Label_42"), pageToken: nil)
        let request = try #require(await transport.requests.first)
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "labelIds" }?.value == "Label_42")
        #expect(query?.contains { $0.name == "includeSpamTrash" } == false)
    }

    @Test("Saved labels are replaced as a whole and kept per account")
    func cache() async throws {
        let cache = try await GmailCache.inMemory()
        let first = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let second = try await cache.session(for: CachedGmailAccount(id: "b", email: "b@example.com"))
        try await first.saveLabels([GmailLabel(id: "Label_1", name: "Old"), GmailLabel(id: "Label_2", name: "Removed")])
        try await second.saveLabels([GmailLabel(id: "Label_1", name: "Other account")])
        let renamed = GmailLabel(id: "Label_1", name: "Renamed", visibility: .showIfUnread, unreadThreads: 3)
        try await first.saveLabels([renamed])
        #expect(try await first.labels() == [renamed])
        #expect(try await second.labels() == [GmailLabel(id: "Label_1", name: "Other account")])
    }

    @Test("A refresh picks labels up, and they outlive a failed request through the cache")
    @MainActor
    func store() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let online = GmailReaderStore(api: LabelReader(labels: [GmailLabel(id: "Label_1", name: "Safety")], counts: ["Label_1": 2]), cache: session)
        await online.refresh()
        #expect(online.labelNames == ["Label_1": "Safety"])
        #expect(online.labels.first?.unreadThreads == 2)

        let offline = GmailReaderStore(api: LabelReader(labels: nil), cache: session)
        await offline.refresh()
        #expect(offline.labelNames == ["Label_1": "Safety"])
        #expect(offline.labelTree.roots.map(\.title) == ["Safety"])
        #expect(offline.labels.first?.unreadThreads == 2)

        offline.reset()
        #expect(offline.labelNames.isEmpty)
        #expect(offline.labelTree.isEmpty)
    }

    @Test("Labels are nested by name, in order, with parents that are not labels themselves")
    func tree() {
        let tree = LabelTree([
            GmailLabel(id: "3", name: "Work/Sentry", unreadThreads: 14),
            GmailLabel(id: "1", name: "Work"),
            GmailLabel(id: "2", name: "Work/Infra", unreadThreads: 1),
            GmailLabel(id: "4", name: "Banks"),
            GmailLabel(id: "5", name: "Projects/Website/Staging", unreadThreads: 2)
        ])
        #expect(tree.roots.map(\.title) == ["Banks", "Projects", "Work"])
        let work = tree.roots[2]
        #expect(work.label?.id == "1")
        #expect(work.children.map(\.title) == ["Infra", "Sentry"])
        #expect(work.unreadThreads == 0)
        #expect(work.unreadThreadsIncludingChildren == 15)
        let projects = tree.roots[1]
        #expect(projects.label == nil)
        #expect(projects.children.first?.label == nil)
        #expect(projects.children.first?.children.first?.path == "Projects/Website/Staging")
        #expect(tree.more.isEmpty)
    }

    @Test("What Gmail doesn't list goes under More, by its whole name, unless a listed label needs it as a parent")
    func treeVisibility() {
        let tree = LabelTree([
            GmailLabel(id: "1", name: "Shown"),
            GmailLabel(id: "2", name: "Hidden", visibility: .hide),
            GmailLabel(id: "3", name: "Quiet", visibility: .showIfUnread),
            GmailLabel(id: "4", name: "Busy", visibility: .showIfUnread, unreadThreads: 1),
            GmailLabel(id: "5", name: "Work", visibility: .hide),
            GmailLabel(id: "6", name: "Work/Infra"),
            GmailLabel(id: "7", name: "Shown/Old", visibility: .hide)
        ])
        #expect(tree.roots.map(\.title) == ["Busy", "Shown", "Work"])
        #expect(tree.roots[2].label?.id == "5")
        #expect(tree.more.map(\.title) == ["Hidden", "Quiet", "Shown/Old"])
    }

    @Test("A name with an empty part is not nested, so it can't take the place of another label")
    func treeOddNames() {
        let tree = LabelTree([GmailLabel(id: "1", name: "Work"), GmailLabel(id: "2", name: "/Work"), GmailLabel(id: "3", name: "Work/")])
        #expect(Set(tree.roots.map(\.title)) == ["Work", "/Work", "Work/"])
        #expect(tree.roots.allSatisfy { $0.children.isEmpty && $0.label != nil })
        #expect(GmailLabel(id: "4", name: "Work/Infra").shortName == "Infra")
        #expect(GmailLabel(id: "5", name: "Work/").shortName == "Work/")
    }

    @Test("A label's folder keeps its identity through the cache's raw value")
    func rawValue() {
        for mailbox in Mailbox.allCases + [.label("Label_42"), .label("Label:with/odd")] {
            #expect(Mailbox(rawValue: mailbox.rawValue) == mailbox)
        }
        #expect(Mailbox.inbox.rawValue == "Inbox")
        #expect(Mailbox(rawValue: "label:") == nil)
        #expect(Mailbox(rawValue: "Nonsense") == nil)
        #expect(Mailbox.allCases.allSatisfy { !$0.isLabel })
    }

    @Test("A conversation is in a label unless the messages with it are in the Spam or the Trash")
    func belongs() {
        #expect(conversation(["Label_1"]).belongs(to: .label("Label_1")))
        #expect(conversation(["INBOX"], ["Label_1"]).belongs(to: .label("Label_1")))
        #expect(!conversation(["INBOX"]).belongs(to: .label("Label_1")))
        #expect(!conversation(["Label_1", "TRASH"]).belongs(to: .label("Label_1")))
        #expect(!conversation(["Label_1", "SPAM"]).belongs(to: .label("Label_1")))
        #expect(conversation(["Label_1", "TRASH"], ["Label_1"]).belongs(to: .label("Label_1")))
    }

    @Test("Unread counts are only asked for when mail has changed, and never for hidden labels")
    @MainActor
    func countRequests() async throws {
        let mail = LabelSyncMail(labels: [
            GmailLabel(id: "Label_1", name: "Work"),
            GmailLabel(id: "Label_2", name: "Quiet", visibility: .showIfUnread),
            GmailLabel(id: "Label_3", name: "Hidden", visibility: .hide)
        ])
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let store = GmailReaderStore(api: mail, cache: session)

        await store.refresh()
        #expect(mail.countRequests.contains("Label_1"))
        #expect(mail.countRequests.contains("Label_2"))
        #expect(!mail.countRequests.contains("Label_3"))
        #expect(store.labels.first { $0.id == "Label_1" }?.unreadThreads == 1)

        mail.countRequests = []
        await store.refresh()
        #expect(mail.countRequests.isEmpty)

        mail.addUnread(to: "Label_1")
        await store.refresh()
        #expect(mail.countRequests.sorted() == ["Label_1", "Label_2"])
        #expect(store.labels.first { $0.id == "Label_1" }?.unreadThreads == 2)
    }

    @Test("A label that can't be read keeps its count and is asked for again at the next refresh")
    @MainActor
    func countFailure() async throws {
        let mail = LabelSyncMail(labels: [GmailLabel(id: "Label_1", name: "Work")])
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let store = GmailReaderStore(api: mail, cache: session)
        await store.refresh()
        #expect(store.labels.first?.unreadThreads == 1)

        mail.failsCounts = true
        mail.addUnread(to: "Label_1")
        await store.refresh()
        #expect(store.labels.first?.unreadThreads == 1)

        mail.failsCounts = false
        mail.countRequests = []
        await store.refresh()
        #expect(mail.countRequests == ["Label_1"])
        #expect(store.labels.first?.unreadThreads == 2)
    }

    @Test("A label's folder is kept up to date by history and cached like any other")
    @MainActor
    func folderSync() async throws {
        let mail = LabelSyncMail(labels: [GmailLabel(id: "Label_1", name: "Work")])
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let store = GmailReaderStore(api: mail, cache: session)
        await store.refresh()
        store.changeMailbox(.label("Label_1"))
        await store.refresh()
        #expect(store.conversations.map(\.id) == ["labelled-1"])

        mail.addUnread(to: "Label_1")
        await store.refresh()
        #expect(store.conversations.map(\.id) == ["labelled-2", "labelled-1"])

        store.changeMailbox(.inbox)
        store.changeMailbox(.label("Label_1"))
        await store.restoreCachedMailbox()
        #expect(store.showingCachedMail)
        #expect(store.conversations.map(\.id) == ["labelled-2", "labelled-1"])
    }

    @Test("A rebuild takes snapshots of the open label only, and the others start over when opened")
    @MainActor
    func rebuildSkipsOtherLabels() async throws {
        let mail = LabelSyncMail(labels: [GmailLabel(id: "Label_1", name: "Work"), GmailLabel(id: "Label_2", name: "Home")])
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        let store = GmailReaderStore(api: mail, cache: session)
        await store.refresh()
        store.changeMailbox(.label("Label_1"))
        await store.refresh()
        store.changeMailbox(.label("Label_2"))
        await store.refresh()
        let cachedBefore = Set(try await session.cachedMailboxes())
        #expect(cachedBefore == [.inbox, .label("Label_1"), .label("Label_2")])

        mail.expiresHistoryOnce = true
        mail.snapshots = []
        await store.refresh()
        #expect(mail.snapshots.contains(.label("Label_2")))
        #expect(!mail.snapshots.contains(.label("Label_1")))
        let cachedAfter = Set(try await session.cachedMailboxes())
        #expect(cachedAfter == [.inbox, .label("Label_2")])
    }
}

@Suite("Gmail labels across accounts", .timeLimit(.minutes(1)))
@MainActor
struct LabelFolderHubTests {
    private func makeHub(_ apis: [String: LabelSyncMail], preferences: UserDefaults? = nil) async -> MailHub {
        let ids = apis.keys.sorted()
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
        let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false, preferences: preferences) { apis[$0]! }
        await hub.reconcile()
        await hub.refresh()
        return hub
    }

    /// Two accounts where the same label ID means something different, as Gmail numbers each account's labels on its own.
    private func twoAccounts() async -> (hub: MailHub, a: LabelSyncMail, b: LabelSyncMail) {
        let a = LabelSyncMail(labels: [GmailLabel(id: "Label_1", name: "Work/Infra")])
        let b = LabelSyncMail(labels: [GmailLabel(id: "Label_1", name: "Family")])
        let hub = await makeHub(["a": a, "b": b])
        hub.selectAccount("a")
        return (hub, a, b)
    }

    @Test("A label opens in the account on screen, under its short name, and leaves the other account alone")
    func opensInOneAccount() async {
        let (hub, a, b) = await twoAccounts()
        a.snapshots = []
        b.snapshots = []
        hub.show(.folder(.label("Label_1")))
        await hub.refresh()
        #expect(hub.selection == .folder(.label("Label_1")))
        #expect(hub.selectionTitle == "Infra")
        #expect(hub.conversations.map(\.key.accountID) == ["a"])
        #expect(hub.conversations.map(\.conversation.id) == ["labelled-1"])
        #expect(a.snapshots == [.label("Label_1")])
        #expect(!b.snapshots.contains(.label("Label_1")))
        #expect(!hub.openLabelIsGone)
    }

    @Test("Switching accounts leaves the label for the Inbox, even when the other account has the same label ID")
    func switchingAccounts() async {
        let (hub, _, _) = await twoAccounts()
        hub.show(.folder(.label("Label_1")))
        hub.selectAccount("b")
        #expect(hub.selection == .folder(.inbox))
        #expect(hub.labelTree.roots.map(\.title) == ["Family"])
    }

    @Test("All Inboxes keeps the selected account's labels, and opening one leaves it for that account")
    func allInboxes() async {
        let (hub, _, _) = await twoAccounts()
        hub.show(.allInboxes)
        #expect(hub.isShowingAllInboxes)
        #expect(hub.labelTree.roots.map(\.title) == ["Work"])

        hub.show(.folder(.label("Label_1")))
        await hub.refresh()
        #expect(!hub.isShowingAllInboxes)
        #expect(hub.selectionTitle == "Infra")
        #expect(hub.conversations.map(\.key.accountID) == ["a"])
        #expect(!hub.openLabelIsGone)

        hub.show(.allInboxes)
        #expect(hub.selection == .allInboxes)
        #expect(hub.mailbox == .inbox)
    }

    @Test("A label deleted in Gmail, or whose account was removed, is noticed")
    func gone() async {
        let (hub, a, _) = await twoAccounts()
        hub.show(.folder(.label("Label_1")))
        #expect(!hub.openLabelIsGone)

        a.labels = []
        await hub.refresh()
        #expect(hub.openLabelIsGone)

        a.labels = [GmailLabel(id: "Label_1", name: "Work/Infra")]
        await hub.refresh()
        #expect(!hub.openLabelIsGone)

        await hub.removeAccount("a")
        #expect(hub.openLabelIsGone)
    }

    @Test("Archiving in a label keeps the conversation there, without the Inbox, and it stays selected")
    func archiving() async {
        let (hub, a, _) = await twoAccounts()
        let model = InboxModel(hub: hub)
        a.addInboxThread(withLabel: "Label_1")
        hub.show(.folder(.label("Label_1")))
        await hub.refresh()
        let inInbox = ConversationKey(accountID: "a", threadID: "labelled-inbox")
        let notInInbox = ConversationKey(accountID: "a", threadID: "labelled-1")
        #expect(hub.canArchive(inInbox))
        #expect(!hub.canArchive(notInInbox))

        model.select(inInbox)
        #expect(await hub.archive(inInbox))
        #expect(hub.conversationKeys.contains(inInbox))
        #expect(model.selectedID == inInbox)
        #expect(a.mail["labelled-inbox"]?.labelIDs.contains("INBOX") == false)
        #expect(hub.conversation(for: inInbox)?.labelIDs.contains("INBOX") == false)
        #expect(!hub.canArchive(inInbox))
    }

    @Test("Trashing in a label takes the conversation out of it")
    func trashing() async {
        let (hub, _, _) = await twoAccounts()
        hub.show(.folder(.label("Label_1")))
        await hub.refresh()
        let key = ConversationKey(accountID: "a", threadID: "labelled-1")
        #expect(hub.canTrash(key))
        #expect(await hub.trash(key))
        #expect(!hub.conversationKeys.contains(key))
    }

    @Test("Which nested labels are collapsed is remembered per account, and forgotten with the account")
    func collapsing() async {
        let preferences = UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)")!
        let apis = ["a": LabelSyncMail(labels: []), "b": LabelSyncMail(labels: [])]
        let hub = await makeHub(apis, preferences: preferences)
        hub.selectAccount("a")
        #expect(hub.isLabelGroupExpanded("Work"))
        hub.setLabelGroup("Work", expanded: false)
        #expect(!hub.isLabelGroupExpanded("Work"))
        hub.selectAccount("b")
        #expect(hub.isLabelGroupExpanded("Work"))

        let reopened = await makeHub(apis, preferences: preferences)
        reopened.selectAccount("a")
        #expect(!reopened.isLabelGroupExpanded("Work"))
        reopened.setLabelGroup("Work", expanded: true)
        #expect(reopened.isLabelGroupExpanded("Work"))

        hub.setLabelGroup("Home", expanded: false)
        await hub.removeAccount("b")
        #expect((preferences.dictionary(forKey: SettingsKey.collapsedLabelGroups)?["b"]) == nil)
    }
}

private actor LabelTransport: GmailTransport {
    let body: String
    private(set) var requests: [URLRequest] = []

    init(body: String) { self.body = body }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        return GmailHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }
}

/// An account with history, where each label starts with one unread conversation that is not in the Inbox.
@MainActor
private final class LabelSyncMail: GmailSyncReading, GmailMutating, GmailSearching, GmailLabelLoading {
    var labels: [GmailLabel]
    var mail: [String: GmailConversation] = [:]
    var countRequests: [String] = []
    var snapshots: [Mailbox] = []
    var failsCounts = false
    var expiresHistoryOnce = false
    private var version = 100
    private var changes: [(version: Int, id: String)] = []

    init(labels: [GmailLabel]) {
        self.labels = labels
        for (index, label) in labels.enumerated() {
            add(index == 0 ? "labelled-1" : "labelled-\(label.id)", order: 1, labels: [label.id, "UNREAD"])
        }
    }

    private func add(_ id: String, order: Int, labels: Set<String>) {
        mail[id] = GmailConversation(id: id, subject: id, messages: [
            GmailMessage(id: id + "-m", senderName: "Sender", senderEmail: "s@example.com", recipient: "me@example.com", cc: "",
                         date: Date(timeIntervalSince1970: 1_700_000_000 + Double(order)), snippet: "", body: "", labelIDs: labels)
        ])
        version += 1
        changes.append((version, id))
    }

    func addUnread(to label: String) { add("labelled-2", order: 2, labels: [label, "UNREAD"]) }
    func addInboxThread(withLabel label: String) { add("labelled-inbox", order: 3, labels: [label, "INBOX"]) }

    @MainActor func userLabels() async throws -> [GmailLabel] { labels }

    @MainActor func unreadThreads(inLabel id: String) async throws -> Int {
        countRequests.append(id)
        if failsCounts { throw GmailError.http(503) }
        return mail.values.filter { $0.labelIDs.isSuperset(of: [id, "UNREAD"]) }.count
    }

    @MainActor func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        snapshots.append(mailbox)
        let conversations = mail.values.filter { $0.belongs(to: mailbox) }.sorted { $0.latestDate > $1.latestDate }
        return GmailPage(conversations: conversations, nextPageToken: nil)
    }

    @MainActor func search(_ query: String, in mailbox: Mailbox?, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: [], nextPageToken: nil)
    }

    @MainActor func conversation(id: String) async throws -> GmailConversation {
        guard let conversation = mail[id] else { throw GmailError.http(404) }
        return conversation
    }

    @MainActor func unreadInboxCount() async throws -> Int { 0 }
    @MainActor func currentHistoryID() async throws -> String { String(version) }
    @MainActor func metadata(id: String) async throws -> GmailConversation? { mail[id] }

    @MainActor func history(startHistoryID: String, pageToken: String?) async throws -> GmailHistoryPage {
        if expiresHistoryOnce {
            expiresHistoryOnce = false
            throw GmailError.http(404)
        }
        let since = Int(startHistoryID) ?? 0
        return GmailHistoryPage(history: changes.filter { $0.version > since }.map {
            GmailHistoryPage.Record(id: String($0.version), messages: [.init(id: $0.id + "-m", threadId: $0.id)],
                                    messagesAdded: nil, messagesDeleted: nil, labelsAdded: nil, labelsRemoved: nil)
        }, nextPageToken: nil, historyId: String(version))
    }

    @MainActor func archive(threadID: String) async throws { try await setLabel("INBOX", on: false, threadID: threadID) }
    @MainActor func trash(threadID: String) async throws { try await setLabel("TRASH", on: true, threadID: threadID) }
    @MainActor func untrash(threadID: String) async throws { try await setLabel("TRASH", on: false, threadID: threadID) }

    @MainActor func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        mail[threadID] = mail[threadID]?.setting(label, to: on)
        version += 1
        changes.append((version, threadID))
    }
}

/// An account with no mail, whose labels can be read only when `labels` is set.
private struct LabelReader: GmailReading, GmailLabelLoading {
    let labels: [GmailLabel]?
    var counts: [String: Int] = [:]

    func userLabels() async throws -> [GmailLabel] {
        guard let labels else { throw GmailError.http(503) }
        return labels
    }

    func unreadThreads(inLabel id: String) async throws -> Int {
        guard let count = counts[id] else { throw GmailError.http(503) }
        return count
    }

    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage { GmailPage(conversations: [], nextPageToken: nil) }
    func conversation(id: String) async throws -> GmailConversation { throw GmailError.http(404) }
    func unreadInboxCount() async throws -> Int { 0 }
}
