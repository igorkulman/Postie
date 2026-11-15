import Foundation
import Testing
@testable import Postie

@MainActor
private final class MutatingStubAPI: GmailReading, GmailMutating {
    let base: StubAPI
    var calls: [String] = []
    var failure: Error?

    init(_ pages: [Result<GmailPage, Error>]) { base = StubAPI(pages) }

    @MainActor
    func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        try await base.mailbox(mailbox, pageToken: pageToken)
    }
    @MainActor
    func conversation(id: String) async throws -> GmailConversation { try await base.conversation(id: id) }
    @MainActor
    func unreadInboxCount() async throws -> Int { try await base.unreadInboxCount() }

    @MainActor
    func archive(threadID: String) async throws { try record("archive \(threadID)") }
    @MainActor
    func trash(threadID: String) async throws { try record("trash \(threadID)") }
    @MainActor
    func untrash(threadID: String) async throws { try record("remove TRASH \(threadID)") }
    @MainActor
    func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        try record("\(on ? "add" : "remove") \(label) \(threadID)")
    }

    private func record(_ call: String) throws {
        if let failure { throw failure }
        calls.append(call)
    }
}

@Suite("Gmail mutations", .timeLimit(.minutes(1)))
struct GmailMutationTests {
    private func body(of request: URLRequest) throws -> [String: [String]] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])
    }

    @Test("Archive removes only the Inbox label with an authorized POST")
    func archiveRequest() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        try await api.archive(threadID: "a1")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/gmail/v1/users/me/threads/a1/modify")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try body(of: request) == ["removeLabelIds": ["INBOX"]])
    }

    @Test("Trash uses the recoverable trash endpoint, never permanent delete")
    func trashRequest() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        try await api.trash(threadID: "a1")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/gmail/v1/users/me/threads/a1/trash")
    }

    @Test("Undo Trash uses Gmail’s untrash endpoint, never a new message or a permanent delete")
    func untrashRequest() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        try await api.untrash(threadID: "a1")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/gmail/v1/users/me/threads/a1/untrash")
    }

    @Test("Labels are added and removed through thread modify", arguments: [
        (true, "addLabelIds"), (false, "removeLabelIds")
    ])
    func labelRequest(input: (Bool, String)) async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        try await api.setLabel("STARRED", on: input.0, threadID: "a1")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/gmail/v1/users/me/threads/a1/modify")
        #expect(try body(of: request) == [input.1: ["STARRED"]])
    }

    @Test("Failed and unsafe mutations surface errors")
    func failures() async throws {
        let denied = GmailAPI(transport: FixtureTransport(mode: .denied)) { "t" }
        await #expect(throws: GmailError.http(401)) { try await denied.archive(threadID: "a1") }
        let api = GmailAPI(transport: FixtureTransport()) { "t" }
        await #expect(throws: GmailError.invalidResponse) { try await api.trash(threadID: "../x") }
    }

    @Test("Setting a label applies to every message")
    func conversationLabels() throws {
        let conversation = try GmailFixtures.conversation("a1", includeBody: false)
        #expect(conversation.isUnread && conversation.isStarred)
        let updated = conversation.setting("UNREAD", to: false).setting("STARRED", to: false)
        #expect(!updated.isUnread && !updated.isStarred)
        #expect(updated.labelIDs.contains("Label_42"))
        #expect(conversation.setting("STARRED", to: true).messages.allSatisfy { $0.labelIDs.contains("STARRED") })
    }

    @Test("Archiving removes the conversation locally after Gmail accepts it")
    @MainActor
    func archiveRemovesRow() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let b = try GmailFixtures.conversation("a2", includeBody: false)
        let api = MutatingStubAPI([.success(GmailPage(conversations: [a, b], nextPageToken: nil)),
                                   .success(GmailPage(conversations: [b], nextPageToken: nil))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        #expect(store.canArchive && store.canTrash)
        #expect(await store.archive("a1"))
        #expect(api.calls == ["archive a1"])
        #expect(store.conversations.map(\.id) == ["a2"])
    }

    @Test("A rejected or timed-out change keeps the row and reports the error", arguments: [false, true])
    @MainActor
    func rejectedChange(transient: Bool) async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = MutatingStubAPI([.success(GmailPage(conversations: [a], nextPageToken: nil))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        api.failure = transient ? URLError(.timedOut) : GmailError.http(403)
        #expect(await store.trash("a1") == false)
        #expect(store.conversations.map(\.id) == ["a1"])
        #expect(store.mailboxError != nil)
        await store.setStarred("a1", false)
        #expect(store.conversations.first?.isStarred == true)
    }

    @Test("Archive and trash are limited to sensible folders")
    @MainActor
    func availability() {
        let api = MutatingStubAPI([])
        #expect(GmailReaderStore(api: api, mailbox: .inbox).canArchive)
        #expect(!GmailReaderStore(api: api, mailbox: .sent).canArchive)
        #expect(GmailReaderStore(api: api, mailbox: .sent).canTrash)
        #expect(!GmailReaderStore(api: api, mailbox: .trash).canTrash)
        #expect(!GmailReaderStore(api: api, mailbox: .outbox).canTrash)
        let readOnly = GmailReaderStore(api: StubAPI([]))
        #expect(!readOnly.canArchive && !readOnly.canTrash && !readOnly.canModifyLabels)
    }

    @Test("Star and read state update the list and open conversation")
    @MainActor
    func labelsUpdateLocally() async throws {
        let a = try GmailFixtures.conversation("a1", includeBody: false)
        let api = MutatingStubAPI([.success(GmailPage(conversations: [a], nextPageToken: nil)),
                                   .success(GmailPage(conversations: [a.setting("STARRED", to: false).setting("UNREAD", to: false)], nextPageToken: nil))])
        let store = GmailReaderStore(api: api)
        await store.refresh()
        await store.select("a1")
        await store.setStarred("a1", false)
        await store.setUnread("a1", false)
        #expect(api.calls == ["remove STARRED a1", "remove UNREAD a1"])
        #expect(store.conversations.first?.isStarred == false)
        #expect(store.conversations.first?.isUnread == false)
        #expect(store.selectedConversation?.isUnread == false)
    }

    @Test("An accepted archive registers native Undo and restores only Inbox membership in the owning account")
    @MainActor
    func undoArchive() async throws {
        let mail = MailHubTests.conversation("thread", at: 100, unread: true).setting("STARRED", to: true)
        let a = MutatingStubAPI([.success(GmailPage(conversations: [mail], nextPageToken: nil))])
        let b = MutatingStubAPI([.success(GmailPage(conversations: [mail], nextPageToken: nil)),
                                 .success(GmailPage(conversations: [], nextPageToken: nil)),
                                 .success(GmailPage(conversations: [mail], nextPageToken: nil))])
        let hub = await MailHubTests().makeHub(["a": a, "b": b])
        let model = InboxModel(hub: hub)
        let manager = UndoManager()
        model.undoManager = manager
        manager.beginUndoGrouping()
        await model.remove(ConversationKey(accountID: "b", threadID: "thread"), archiving: true)?.value
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Archive")
        let notice = try #require(model.removalNotice)
        await notice.undo()?.value
        #expect(notice.isUndone)
        #expect(!notice.canUndo)
        #expect(notice.undo() == nil)
        #expect(a.calls.isEmpty)
        #expect(b.calls == ["archive thread", "add INBOX thread"])
        #expect(hub.conversationKeys.contains(ConversationKey(accountID: "b", threadID: "thread")))
    }

    @Test("Undo Trash preserves an archived message’s location, and failed inverses can be retried")
    @MainActor
    func undoTrashRetry() async throws {
        let mail = MailHubTests.conversation("thread", at: 100).setting("INBOX", to: false)
        let api = MutatingStubAPI([.success(GmailPage(conversations: [mail], nextPageToken: nil)),
                                   .success(GmailPage(conversations: [mail], nextPageToken: nil))])
        let hub = await MailHubTests().makeHub(["a": api])
        let receipt = MailRemovalReceipt(key: ConversationKey(accountID: "a", threadID: "thread"), archiving: false, labels: ["SENT"])
        let operation = MailRemovalUndo(receipts: [receipt], hub: hub)
        api.failure = GmailError.http(403)
        await operation.undo()?.value
        #expect(operation.error != nil && operation.canUndo)
        api.failure = nil
        await operation.undo()?.value
        #expect(operation.isUndone)
        #expect(api.calls == ["remove TRASH thread", "remove SPAM thread", "remove INBOX thread"])
    }
}
