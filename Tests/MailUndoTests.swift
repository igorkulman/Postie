import Foundation
import Testing
@testable import Postie

@Suite("Undo", .timeLimit(.minutes(1)))
@MainActor
struct MailUndoTests {
    private func key(_ id: String, account: String = "a") -> ConversationKey {
        ConversationKey(accountID: account, threadID: id)
    }

    private func threadIDs(_ hub: MailHub) -> [String] { hub.conversations.map(\.key.threadID) }

    private func until(_ condition: () async -> Bool) async throws {
        while await !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// An inbox of a1 (newest), a2 and a3, with an undo history of its own.
    private func makeInbox(_ api: HubAPI? = nil) async -> (HubAPI, MailHub, InboxModel, UndoManager) {
        let api = api ?? HubAPI([
            MailHubTests.conversation("a1", at: 300), MailHubTests.conversation("a2", at: 200), MailHubTests.conversation("a3", at: 100)
        ])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub)
        let manager = UndoManager()
        model.undoManager = manager
        return (api, hub, model, manager)
    }

    @Test("Undoing an archive puts the conversation back in its place, selected, and Redo archives it again")
    func archiveUndoRedo() async throws {
        let (api, hub, model, manager) = await makeInbox()
        model.select(key("a2"))
        model.remove(key("a2"), archiving: true)
        try await until { manager.canUndo }
        #expect(manager.undoActionName == "Archive")
        #expect(threadIDs(hub) == ["a1", "a3"])
        #expect(model.selectedID == key("a3"))

        manager.undo()
        try await until { threadIDs(hub).contains("a2") && model.selectedID == key("a2") }
        #expect(threadIDs(hub) == ["a1", "a2", "a3"])
        #expect(await api.labelChanges == ["add INBOX a2"])
        #expect(manager.redoActionName == "Archive")

        manager.redo()
        try await until { !threadIDs(hub).contains("a2") }
        try await until { model.selectedID == key("a3") }
        #expect(await api.archived == ["a2", "a2"])
        #expect(manager.undoActionName == "Archive")
    }

    @Test("Undo goes back through several actions, newest first")
    func severalLevels() async throws {
        let (_, hub, model, manager) = await makeInbox()
        model.remove(key("a1"), archiving: true)
        try await until { manager.undoActionName == "Archive" }
        model.remove(key("a2"), archiving: false)
        try await until { manager.undoActionName == "Move to Trash" }
        #expect(threadIDs(hub) == ["a3"])

        // Choosing Undo twice without waiting for Gmail, as holding down Command-Z does.
        manager.undo()
        #expect(manager.undoActionName == "Archive")
        manager.undo()
        #expect(!manager.canUndo)
        try await until { threadIDs(hub).contains("a1") }
        #expect(manager.redoActionName == "Archive")
    }

    @Test("Undoing a trash brings the conversation back to the Inbox")
    func trashComesBackToInbox() async throws {
        let (api, hub, model, manager) = await makeInbox()
        model.remove(key("a1"), archiving: false)
        try await until { manager.canUndo }
        #expect(manager.undoActionName == "Move to Trash")
        manager.undo()
        try await until { threadIDs(hub).contains("a1") }
        #expect(await api.labelChanges == ["untrash a1", "add INBOX a1"])
        try await until { await api.mail.contains { $0.id == "a1" } }
    }

    @Test("Removing several is one step, named with how many, and all of them come back selected")
    func bulk() async throws {
        let (_, hub, model, manager) = await makeInbox()
        let keys = [key("a1"), key("a2")]
        model.updateFromList(Set(keys))
        model.remove(keys, archiving: true)
        try await until { manager.canUndo }
        #expect(manager.undoActionName == "Archive 2 Conversations")
        manager.undo()
        #expect(!manager.canUndo)
        try await until { threadIDs(hub) == ["a1", "a2", "a3"] && model.selectedCount == 2 }
        #expect(Set(model.selectedKeys) == Set(keys))
    }

    @Test("A conversation that was removed unread stays unread when undoing opens it")
    func undoKeepsItUnread() async throws {
        let api = HubAPI([MailHubTests.conversation("a1", at: 300, unread: true)])
        let (_, _, model, manager) = await makeInbox(api)
        model.remove(key("a1"), archiving: true)
        try await until { manager.canUndo }
        manager.undo()
        try await until { model.selectedID == key("a1") }
        await model.openSelection()
        #expect(await !api.labelChanges.contains("remove UNREAD a1"))
    }

    @Test("Flag and read changes can be undone and redone, and name what they did")
    func labels() async throws {
        let api = HubAPI([MailHubTests.conversation("a1", at: 300)])
        let (_, hub, model, manager) = await makeInbox(api)
        let item = try #require(hub.conversations.first)

        model.toggleStar(item)
        try await until { manager.undoActionName == "Flag" }
        #expect(hub.conversations.first?.conversation.isStarred == true)
        model.toggleRead(try #require(hub.conversations.first))
        try await until { manager.undoActionName == "Mark as Unread" }

        manager.undo()
        try await until { hub.conversations.first?.conversation.isUnread == false }
        #expect(manager.redoActionName == "Mark as Unread")
        manager.undo()
        try await until { hub.conversations.first?.conversation.isStarred == false }
        #expect(!manager.canUndo)
        manager.redo()
        try await until { hub.conversations.first?.conversation.isStarred == true }
        #expect(await api.labelChanges == [
            "add STARRED a1", "add UNREAD a1", "remove UNREAD a1", "remove STARRED a1", "add STARRED a1"
        ])
    }

    @Test("Opening a conversation marks it read without adding a step to undo")
    func automaticReadIsNotAStep() async throws {
        let api = HubAPI([MailHubTests.conversation("a1", at: 300, unread: true)])
        let (_, _, model, manager) = await makeInbox(api)
        model.select(key("a1"))
        await model.openSelection()
        try await until { await api.labelChanges.contains("remove UNREAD a1") }
        #expect(!manager.canUndo)
    }

    @Test("What Gmail refused adds no step, and neither does deleting a draft for good")
    func nothingToUndo() async throws {
        let (api, hub, model, manager) = await makeInbox()
        #expect(hub.canUndoRemoval(archiving: false))
        await api.failRequests(with: .http(403))
        model.select(key("a1"))
        model.remove(key("a1"), archiving: true)
        try await until { !hub.notices.isEmpty }
        #expect(!manager.canUndo)
        #expect(threadIDs(hub).contains("a1"))

        hub.changeMailbox(.drafts)
        #expect(!hub.canUndoRemoval(archiving: false))
    }

    @Test("An undo Gmail refuses shows why and can be tried again")
    func refusedUndo() async throws {
        let (api, hub, model, manager) = await makeInbox()
        model.remove(key("a1"), archiving: true)
        try await until { manager.canUndo }
        await api.failRequests(with: .http(503))
        manager.undo()
        try await until { manager.canUndo && !hub.notices.isEmpty }
        #expect(!threadIDs(hub).contains("a1"))
        #expect(!manager.canRedo)
        #expect(manager.undoActionName == "Archive")

        await api.failRequests(with: nil)
        manager.undo()
        try await until { threadIDs(hub).contains("a1") }
    }

    @Test("Undoing from another folder changes Gmail without touching what is selected there")
    func undoFromAnotherFolder() async throws {
        let (api, hub, model, manager) = await makeInbox()
        model.remove(key("a1"), archiving: true)
        try await until { manager.canUndo }
        model.changeMailbox(.sent)
        await hub.refresh()
        manager.undo()
        try await until { await api.labelChanges == ["add INBOX a1"] }
        #expect(model.selectedID == nil)
        #expect(hub.conversations.isEmpty)

        // Redo has to work here too, although Archive is not available in Sent.
        manager.redo()
        try await until { await api.archived == ["a1", "a1"] }
    }

    @Test("Undo returns a search result to the results it left")
    func undoInSearch() async throws {
        let (_, hub, model, manager) = await makeInbox()
        model.searchText = "a2"
        #expect(model.applySearch())
        await hub.performSearch()
        #expect(threadIDs(hub) == ["a2"])
        model.remove(key("a2"), archiving: true)
        try await until { manager.canUndo }
        #expect(threadIDs(hub).isEmpty)
        manager.undo()
        try await until { threadIDs(hub) == ["a2"] && model.selectedID == key("a2") }
    }

    @Test("Undo reaches each conversation's own account")
    func acrossAccounts() async throws {
        let a = HubAPI([MailHubTests.conversation("a1", at: 300)])
        let b = HubAPI([MailHubTests.conversation("b1", at: 200)])
        let hub = await MailHubTests().makeHub(["a": a, "b": b])
        let model = InboxModel(hub: hub)
        let manager = UndoManager()
        model.undoManager = manager
        let keys = [key("a1"), key("b1", account: "b")]
        model.updateFromList(Set(keys))
        model.remove(keys, archiving: false)
        try await until { manager.canUndo }
        manager.undo()
        try await until { hub.conversations.count == 2 }
        #expect(await a.labelChanges == ["untrash a1", "add INBOX a1"])
        #expect(await b.labelChanges == ["untrash b1", "add INBOX b1"])
    }

    // MARK: With the real cache and history sync

    private func regressionKey(_ id: String) -> ConversationKey {
        ConversationKey(accountID: SelectionRegressionMail.accountID, threadID: id)
    }

    @Test("A restored conversation stays after syncing, and so in the cache", arguments: [true, false])
    func restoredThroughSync(archiving: Bool) async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        await hub.refresh()
        let model = InboxModel(hub: hub)
        let manager = UndoManager()
        model.undoManager = manager
        model.remove(regressionKey("open"), archiving: archiving)
        try await until { manager.canUndo }
        await hub.refresh()
        #expect(threadIDs(hub) == ["older"])

        manager.undo()
        try await until { threadIDs(hub) == ["open", "older"] }
        await hub.refresh()
        #expect(threadIDs(hub) == ["open", "older"])
        let restored = try await mail.conversation(id: "open")
        #expect(restored.labelIDs.contains("INBOX") && !restored.labelIDs.contains("TRASH"))
        hub.changeMailbox(archiving ? .archive : .trash)
        await hub.refresh()
        #expect(!threadIDs(hub).contains("open"))
    }

    @Test("A sync already running when the undo happens does not take the conversation away again")
    func undoDuringSync() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        await hub.refresh()
        let model = InboxModel(hub: hub)
        let manager = UndoManager()
        model.undoManager = manager
        model.select(regressionKey("open"))
        // Hold the sync that follows the archive once it has read the conversation as archived.
        var held = false
        var released = false
        mail.afterFetchingMetadata = {
            mail.afterFetchingMetadata = nil
            held = true
            while !released { try? await Task.sleep(for: .milliseconds(5)) }
        }
        model.remove(regressionKey("open"), archiving: true)
        try await until { manager.canUndo && held }

        manager.undo()
        try await until { threadIDs(hub) == ["open", "older"] && model.selectedID == regressionKey("open") }
        released = true
        // The held sync finishes with what it read, then the refresh that was asked for during it runs.
        try await until { hub.isLoadingMailbox == false }
        #expect(threadIDs(hub) == ["open", "older"])
        #expect(model.selectedID == regressionKey("open"))
        let cached = try await hub.sessions.first?.reader.fullConversation("open")
        #expect(cached?.labelIDs.contains("INBOX") == true)
    }
}
