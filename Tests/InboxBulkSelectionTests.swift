import Testing
@testable import Postie

@Suite("Bulk inbox triage", .timeLimit(.minutes(1)))
@MainActor
struct InboxBulkSelectionTests {
    @Test("Multiple selection closes the reader and disables reply until one conversation remains")
    func readerState() async throws {
        let hub = await MailHubTests().makeHub([
            "a": HubAPI([MailHubTests.conversation("one", at: 200), MailHubTests.conversation("two", at: 100)])
        ])
        let model = InboxModel(hub: hub)
        model.reconcileSelection()
        await model.openSelection()
        let keys = Set(hub.conversationKeys)
        model.updateFromList(keys)
        await model.openSelection()
        #expect(model.selectedID == nil)
        #expect(model.selectedIDs == keys)
        #expect(model.openConversation == nil)
        #expect(model.mailActions.reply == nil)
        #expect(model.mailActions.archive != nil && model.mailActions.toggleRead != nil)
        model.updateFromList(Set([try #require(keys.first)]))
        #expect(model.selectedID != nil)
        #expect(model.selectedIDs.count == 1)
    }

    @Test("A captured batch settles independently, keeps later navigation, and offers Undo only for accepted items")
    func partialFailure() async throws {
        let first = MailHubTests.conversation("first", at: 300)
        let second = MailHubTests.conversation("second", at: 200)
        let third = MailHubTests.conversation("third", at: 100)
        let api = ControlledRemovalAPI([first, second, third])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub)
        let keys: Set<ConversationKey> = [ConversationKey(accountID: "a", threadID: "first"),
                                         ConversationKey(accountID: "a", threadID: "second")]
        model.updateFromList(keys)
        let operation = model.remove(keys, archiving: true)
        await api.waitForRemoval("first")
        await api.waitForRemoval("second")
        #expect(hub.conversationKeys.map(\.threadID) == ["third"])
        model.select(nil)
        api.page = GmailPage(conversations: [second, third], nextPageToken: nil)
        api.finishRemoval("first", result: .success(()))
        api.finishRemoval("second", result: .failure(GmailError.http(403)))
        await operation.value
        #expect(hub.conversationKeys.map(\.threadID) == ["second", "third"])
        #expect(model.selectedID == nil)
        #expect(model.removalNotice?.count == 1)
    }

    @Test("Actions are disabled when any selected conversation cannot be modified")
    func mixedCapabilities() async {
        let hub = await MailHubTests().makeHub([
            "a": HubAPI([MailHubTests.conversation("one", at: 200)]),
            "b": StubAPI([.success(GmailPage(conversations: [MailHubTests.conversation("two", at: 100)], nextPageToken: nil))])
        ])
        let model = InboxModel(hub: hub)
        model.updateFromList(Set(hub.conversationKeys))
        #expect(model.mailActions.archive == nil)
        #expect(model.mailActions.trash == nil)
        #expect(model.mailActions.toggleRead == nil)
    }
}
