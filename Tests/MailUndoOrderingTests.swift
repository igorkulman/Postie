import Testing
@testable import Postie

@Suite("Undo ordering", .timeLimit(.minutes(1)))
@MainActor
struct MailUndoOrderingTests {
    @Test("Undo waits for an obsolete in-flight refresh before fetching the restored conversation")
    func refreshAfterUndo() async throws {
        let mail = MailHubTests.conversation("first", at: 100)
        let key = ConversationKey(accountID: "a", threadID: "first")
        let api = ControlledRemovalAPI([mail])
        let hub = await MailHubTests().makeHub(["a": api])
        let archive = Task { await hub.archive(key) }
        await api.waitForRemoval("first")
        api.page = GmailPage(conversations: [], nextPageToken: nil)
        api.finishRemoval("first", result: .success(()))
        #expect(await archive.value)
        api.holdsMailbox = true
        let background = Task { await hub.refresh() }
        await api.waitForMailbox()
        let receipt = MailRemovalReceipt(key: key, archiving: true, labels: ["INBOX"])
        let undo = MailRemovalUndo(receipts: [receipt], hub: hub)
        let restoration = try #require(undo.undo())
        await api.waitForLabelWrites(1)
        #expect(undo.isRestoring)
        api.page = GmailPage(conversations: [mail], nextPageToken: nil)
        api.holdsMailbox = false
        api.finishMailbox(GmailPage(conversations: [], nextPageToken: nil))
        await background.value
        await restoration.value
        #expect(undo.isUndone)
        #expect(hub.conversationKeys == [key])
    }

    @Test("Consecutive Undo requests complete in invocation order, even while untrash is stalled")
    func consecutiveUndo() async throws {
        let api = ControlledRemovalAPI([])
        let hub = await MailHubTests().makeHub(["a": api])
        let key = ConversationKey(accountID: "a", threadID: "first")
        api.holdsUntrash = true
        let trash = MailRemovalUndo(receipts: [MailRemovalReceipt(key: key, archiving: false, labels: [])], hub: hub)
        let archive = MailRemovalUndo(receipts: [MailRemovalReceipt(key: key, archiving: true, labels: ["INBOX"])], hub: hub)
        let first = try #require(trash.undo())
        await api.waitForUntrash()
        let second = try #require(archive.undo())
        api.finishUntrash()
        await first.value
        await second.value
        #expect(api.labelWrites.map { "\($0.label)=\($0.on)" } == ["SPAM=false", "INBOX=false", "INBOX=true"])
        #expect(trash.isUndone && archive.isUndone)
    }
}
