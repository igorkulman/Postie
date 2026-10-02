import Foundation
import Testing
@testable import Postie

@Suite("Gmail selection regression", .timeLimit(.minutes(1)))
@MainActor
struct GmailSelectionRegressionTests {
    private func key(_ id: String) -> ConversationKey {
        ConversationKey(accountID: SelectionRegressionMail.accountID, threadID: id)
    }

    @Test("Cached thread survives newer history mail, then archive opens its older neighbor and empties cleanly")
    func insertionArchiveAndEmpty() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        var selection = ConversationSelection<ConversationKey>()
        selection.reconcile(with: hub.conversations.map(\.key))
        #expect(hub.showingCachedMail)
        #expect(selection.selectedID == key("open"))
        await hub.select(selection.selectedID)
        let original = try #require(hub.openConversation(for: selection.selectedID))

        mail.insertNewerMail()
        await hub.refresh()
        selection.reconcile(with: hub.conversations.map(\.key))
        #expect(hub.conversations.map(\.key) == [key("arrival-1"), key("open"), key("older")])
        #expect(selection.selectedID == key("open"))
        #expect(hub.openConversation(for: selection.selectedID) == original)
        #expect(!hub.showingCachedMail)

        let open = key("open")
        let tokenRequest = selection.beginRemoval(of: open, visibleIDs: hub.conversations.map(\.key))
        let token = try #require(tokenRequest)
        var notified = false
        let archived = await hub.archive(open) {
            notified = true
            #expect(hub.conversation(for: open) == nil)
            #expect(hub.openConversation(for: open) == nil)
            selection.finishRemoval(token, removed: true, visibleIDs: hub.conversations.map(\.key))
            #expect(selection.selectedID == key("older"))
        }
        #expect(archived && notified)
        selection.reconcile(with: hub.conversations.map(\.key))
        await hub.select(selection.selectedID)
        #expect(hub.openConversation(for: selection.selectedID)?.id == "older")

        // Consume the older neighbor, then the newer fallback, then the empty state.
        for expected in ["older", "arrival-1"] {
            let current = try #require(selection.selectedID)
            #expect(current == key(expected))
            let tokenRequest = selection.beginRemoval(of: current, visibleIDs: hub.conversations.map(\.key))
            let token = try #require(tokenRequest)
            #expect(await hub.archive(current) {
                selection.finishRemoval(token, removed: true, visibleIDs: hub.conversations.map(\.key))
            })
            selection.reconcile(with: hub.conversations.map(\.key))
            await hub.select(selection.selectedID)
        }
        #expect(selection.selectedID == nil)
        #expect(hub.conversations.isEmpty)
        #expect(hub.openConversation(for: nil) == nil)
        #expect(hub.sessions.allSatisfy { $0.reader.selectedConversation == nil })
        #expect(!hub.canArchive(selection.selectedID) && !hub.canTrash(selection.selectedID))

        mail.insertNewerMail()
        await hub.refresh()
        selection.reconcile(with: hub.conversations.map(\.key))
        #expect(hub.loadedCount == 1)
        #expect(selection.selectedID == nil)
        #expect(hub.openConversation(for: selection.selectedID) == nil)
    }

    @Test("Rejected Gmail archive preserves both the selected key and open detail")
    func rejectedArchive() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        var selection = ConversationSelection<ConversationKey>()
        selection.reconcile(with: hub.conversations.map(\.key))
        await hub.select(selection.selectedID)
        let current = try #require(selection.selectedID)
        let original = hub.openConversation(for: current)
        let tokenRequest = selection.beginRemoval(of: current, visibleIDs: hub.conversations.map(\.key))
        let token = try #require(tokenRequest)
        mail.rejectNextRemoval = true
        var notified = false
        let archived = await hub.archive(current) { notified = true }
        selection.finishRemoval(token, removed: archived, visibleIDs: hub.conversations.map(\.key))
        #expect(!archived && !notified)
        #expect(selection.selectedID == current)
        #expect(hub.openConversation(for: current) == original)
        #expect(hub.loadedCount == 2)
        #expect(!hub.notices.isEmpty)
    }

    @Test("External archive clears highlight and detail instead of opening newer mail")
    func externalArchive() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        var selection = ConversationSelection<ConversationKey>()
        selection.reconcile(with: hub.conversations.map(\.key))
        await hub.select(selection.selectedID)
        mail.insertNewerMail()
        try await mail.archive(threadID: "open")
        await hub.refresh()
        selection.reconcile(with: hub.conversations.map(\.key))
        await hub.select(selection.selectedID)
        #expect(hub.loadedCount == 2)
        #expect(selection.selectedID == nil)
        #expect(hub.sessions.allSatisfy { $0.reader.selectedConversation == nil })
    }
}
