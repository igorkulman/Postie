import Foundation
import Testing
@testable import Postie

@Suite("Optimistic conversation removal", .timeLimit(.minutes(1)))
@MainActor
struct OptimisticRemovalTests {
    private let key = ConversationKey(accountID: "a", threadID: "first")
    private let first = MailHubTests.conversation("first", at: 300)
    private let second = MailHubTests.conversation("second", at: 200)

    @Test("Archive and Trash disappear before Gmail responds and return on failure", arguments: [true, false])
    func immediateRemovalAndRollback(archiving: Bool) async {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api])
        await hub.select(key)
        var notified = false
        let operation = Task {
            if archiving { return await hub.archive(key) { notified = true } }
            return await hub.trash(key) { notified = true }
        }
        await api.waitForRemoval("first")
        #expect(notified)
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
        #expect(hub.openConversation(for: key) == nil)
        #expect(!hub.canArchive(key) && !hub.canTrash(key))

        // A background response must not make the pending row flash back into view.
        await hub.refresh()
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
        api.finishRemoval("first", result: .failure(GmailError.http(403)))
        #expect(await operation.value == false)
        #expect(hub.conversationKeys.map(\.threadID) == ["first", "second"])
        #expect(!hub.notices.isEmpty)
    }

    @Test("Rollback restores the opening only if the user has not navigated", arguments: [0, 1, 2])
    func selectionRollback(navigation: Int) async throws {
        let third = MailHubTests.conversation("third", at: 100)
        let api = ControlledRemovalAPI([first, second, third])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub)
        model.reconcileSelection()
        await model.openSelection()
        let operation = try #require(model.remove(key, archiving: true))
        await api.waitForRemoval("first")
        #expect(model.selectedID?.threadID == "second")
        #expect(model.listFocusRequest == 1)
        await model.openSelection()
        if navigation > 0 {
            model.select(ConversationKey(accountID: "a", threadID: "third"))
            if navigation == 2 { model.select(ConversationKey(accountID: "a", threadID: "second")) }
        }
        api.finishRemoval("first", result: .failure(GmailError.http(403)))
        await operation.value
        let expected = ["first", "third", "second"][navigation]
        #expect(model.selectedID?.threadID == expected)
        await model.openSelection()
        #expect(hub.openConversation(for: model.selectedID)?.id == expected)
        #expect(model.listFocusRequest == 1)
    }

    @Test("Overlapping removals settle independently without stealing the latest selection")
    func overlappingRemovals() async throws {
        let third = MailHubTests.conversation("third", at: 100)
        let api = ControlledRemovalAPI([first, second, third])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub)
        model.reconcileSelection()
        let firstRemoval = try #require(model.remove(key, archiving: true))
        await api.waitForRemoval("first")
        let secondRemoval = try #require(model.remove(ConversationKey(accountID: "a", threadID: "second"), archiving: false))
        await api.waitForRemoval("second")
        #expect(model.conversationKeys.map(\.threadID) == ["third"])
        #expect(model.selectedID?.threadID == "third")
        api.finishRemoval("first", result: .failure(GmailError.http(403)))
        await firstRemoval.value
        #expect(model.conversationKeys.map(\.threadID) == ["first", "third"])
        #expect(model.selectedID?.threadID == "third")
        api.page = GmailPage(conversations: [first, third], nextPageToken: nil)
        api.finishRemoval("second", result: .success(()))
        await secondRemoval.value
        #expect(model.conversationKeys.map(\.threadID) == ["first", "third"])
        #expect(model.selectedID?.threadID == "third")
    }

    @Test("A pending action cannot be sent twice or hide the same thread ID in another account")
    func duplicateAndAccountIsolation() async {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api, "b": HubAPI([first])])
        let operation = Task { await hub.archive(key) }
        await api.waitForRemoval("first")
        #expect(await hub.trash(key) == false)
        #expect(hub.conversationKeys.contains(ConversationKey(accountID: "b", threadID: "first")))
        api.finishRemoval("first", result: .failure(GmailError.http(403)))
        #expect(await operation.value == false)
    }

    @Test("Changing folders during a failed removal never restores the old selection")
    func folderChangeDuringFailure() async throws {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub)
        model.reconcileSelection()
        let operation = try #require(model.remove(key, archiving: true))
        await api.waitForRemoval("first")
        model.changeMailbox(.sent)
        await hub.refresh()
        model.reconcileSelection()
        model.select(ConversationKey(accountID: "a", threadID: "second"))
        api.finishRemoval("first", result: .failure(GmailError.http(403)))
        await operation.value
        #expect(model.selectedID?.threadID == "second")
        #expect(hub.mailbox == .sent)
    }

    @Test("A refresh started before archive cannot resurrect the accepted removal")
    func staleMailboxResponse() async {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api])
        let stale = api.page
        api.holdsMailbox = true
        let refresh = Task { await hub.refresh() }
        await api.waitForMailbox()
        let operation = Task { await hub.archive(key) }
        await api.waitForRemoval("first")
        api.finishRemoval("first", result: .success(()))
        #expect(await operation.value)
        api.finishMailbox(stale)
        await refresh.value
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
    }

    @Test("Search hides pending removals and restores them when Gmail rejects the action")
    func searchRollback() async {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api])
        hub.setSearch("subject", scope: .allMail)
        await hub.performSearch()
        let operation = Task { await hub.trash(key) }
        await api.waitForRemoval("first")
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
        await hub.performSearch()
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
        api.finishRemoval("first", result: .failure(URLError(.timedOut)))
        #expect(await operation.value == false)
        #expect(hub.conversationKeys.map(\.threadID) == ["first", "second"])
    }

    @Test("Search begun before an accepted removal cannot put the conversation back")
    func staleSearchResponse() async {
        let api = ControlledRemovalAPI([first, second])
        let hub = await MailHubTests().makeHub(["a": api])
        hub.setSearch("subject", scope: .allMail)
        await hub.performSearch()
        let stale = api.page
        api.holdsSearch = true
        let search = Task { await hub.performSearch() }
        await api.waitForSearch()
        let operation = Task { await hub.archive(key) }
        await api.waitForRemoval("first")
        api.page = GmailPage(conversations: [second], nextPageToken: nil)
        api.finishRemoval("first", result: .success(()))
        #expect(await operation.value)
        api.finishSearch(stale)
        await search.value
        #expect(hub.conversationKeys.map(\.threadID) == ["second"])
    }
}
