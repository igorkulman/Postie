import Testing
@testable import Postie

@Suite("Reader conversation navigation")
@MainActor
struct InboxNavigationTests {
    @Test("Toolbar actions follow live mailbox order, stop at the ends and do not choose for an empty selection")
    func toolbarNavigation() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        let model = InboxModel(hub: hub)
        model.reconcileSelection()
        let open = ConversationKey(accountID: SelectionRegressionMail.accountID, threadID: "open")
        let older = ConversationKey(accountID: SelectionRegressionMail.accountID, threadID: "older")
        #expect(model.selectedID == open)
        #expect(model.mailActions.previousConversation == nil)

        let next = try #require(model.mailActions.nextConversation)
        next()
        #expect(model.selectedID == older)
        #expect(model.mailActions.nextConversation == nil)

        mail.insertNewerMail()
        await hub.refresh()
        let previous = try #require(model.mailActions.previousConversation)
        previous()
        #expect(model.selectedID == open)
        let newer = try #require(model.mailActions.previousConversation)
        newer()
        #expect(model.selectedID?.threadID == "arrival-1")
        #expect(model.mailActions.previousConversation == nil)

        model.select(nil)
        #expect(model.mailActions.previousConversation == nil)
        #expect(model.mailActions.nextConversation == nil)
    }
}
