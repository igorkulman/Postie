import Foundation
import Testing
@testable import Postie

@Suite("Conversation selection policy")
@MainActor
struct ConversationSelectionTests {
    @Test("An empty List's redundant deselection does not consume initial cache selection")
    func initialListDeselects() {
        var selection = ConversationSelection<String>()
        selection.updateFromList(nil, visibleIDs: [])
        selection.reconcile(with: ["open"])
        #expect(selection.selectedID == "open")
    }

    @Test("Replacing cached rows and inserting newer mail preserves conversation identity")
    func insertion() {
        var selection = ConversationSelection<String>()
        selection.reconcile(with: ["open", "older"])
        selection.reconcile(with: ["new", "open", "older"])
        #expect(selection.selectedID == "open")
    }

    @Test("Archive selects the next older identity, not the row at the old position")
    func archiveAfterInsertion() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["new", "open", "older"])
        let token = try #require(tokenRequest)
        // Another insertion and a reorder happen while the archive request is in flight.
        selection.finishRemoval(token, removed: true, visibleIDs: ["newer", "older", "new"])
        #expect(selection.selectedID == "older")
    }

    @Test("Vanished neighbors are skipped; newer mail is the fallback")
    func missingNeighbors() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["new", "open", "older", "oldest"])
        let token = try #require(tokenRequest)
        selection.finishRemoval(token, removed: true, visibleIDs: ["arrived", "new", "oldest"])
        #expect(selection.selectedID == "oldest")
        selection.select("oldest")
        let lastRequest = selection.beginRemoval(of: "oldest", visibleIDs: ["arrived", "new", "oldest"])
        let last = try #require(lastRequest)
        selection.finishRemoval(last, removed: true, visibleIDs: ["arrived", "new"])
        #expect(selection.selectedID == "new")
    }

    @Test("Background disappearance clears selection instead of opening the first row")
    func externalRemoval() {
        var selection = ConversationSelection<String>()
        selection.select("open")
        selection.reconcile(with: ["new", "older"])
        #expect(selection.selectedID == nil)
        selection.reconcile(with: ["newest", "new", "older"])
        #expect(selection.selectedID == nil)
    }

    @Test("Archiving the last conversation clears selection, even after another arrival")
    func emptyInbox() throws {
        var selection = ConversationSelection<String>()
        selection.reconcile(with: ["open"])
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["open"])
        let token = try #require(tokenRequest)
        selection.finishRemoval(token, removed: true, visibleIDs: [])
        #expect(selection.selectedID == nil)
        selection.reconcile(with: ["new"])
        #expect(selection.selectedID == nil)
    }

    @Test("Rejected removal keeps selection and permits retry")
    func failure() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["open", "older"])
        let token = try #require(tokenRequest)
        let duplicate = selection.beginRemoval(of: "open", visibleIDs: ["open", "older"])
        #expect(duplicate == nil)
        selection.finishRemoval(token, removed: false, visibleIDs: ["open", "older"])
        #expect(selection.selectedID == "open")
        #expect(!selection.isRemoving("open"))
        let retry = selection.beginRemoval(of: "open", visibleIDs: ["open", "older"])
        #expect(retry != nil)
    }

    @Test("Changing selection during archive wins, even when returning to the same thread")
    func userSelectionWins() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["open", "other", "older"])
        let token = try #require(tokenRequest)
        selection.select("other")
        selection.select("open")
        selection.finishRemoval(token, removed: true, visibleIDs: ["other", "older"])
        selection.reconcile(with: ["other", "older"])
        #expect(selection.selectedID == nil)
    }

    @Test("Removing an unselected row and overlapping operations preserve the open thread")
    func overlappingRemovals() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let otherRequest = selection.beginRemoval(of: "other", visibleIDs: ["other", "open", "older"])
        let other = try #require(otherRequest)
        let openRequest = selection.beginRemoval(of: "open", visibleIDs: ["other", "open", "older"])
        let open = try #require(openRequest)
        selection.finishRemoval(other, removed: true, visibleIDs: ["open", "older"])
        #expect(selection.selectedID == "open")
        #expect(selection.isRemoving("open"))
        selection.finishRemoval(open, removed: true, visibleIDs: ["older"])
        #expect(selection.selectedID == "older")
    }

    @Test("List deselection on removal applies the same neighbor policy")
    func listDeselectsRemovedRow() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["new", "open", "older"])
        let token = try #require(tokenRequest)
        selection.updateFromList(nil, visibleIDs: ["new", "older"])
        #expect(selection.selectedID == "older")
        selection.finishRemoval(token, removed: true, visibleIDs: ["new", "older"])
        #expect(selection.selectedID == "older")
    }

    @Test("Folder reset invalidates pending removals and allows one initial selection")
    func folderChange() throws {
        var selection = ConversationSelection<String>()
        selection.select("open")
        let tokenRequest = selection.beginRemoval(of: "open", visibleIDs: ["open", "older"])
        let token = try #require(tokenRequest)
        selection.reset()
        selection.reconcile(with: [])
        selection.reconcile(with: ["sent"])
        selection.finishRemoval(token, removed: true, visibleIDs: ["sent"])
        #expect(selection.selectedID == "sent")
        selection.select(nil)
        selection.reconcile(with: ["new", "sent"])
        #expect(selection.selectedID == nil)
    }

    @Test("Account identity disambiguates equal Gmail thread IDs")
    func accounts() throws {
        let a = ConversationKey(accountID: "a", threadID: "same")
        let b = ConversationKey(accountID: "b", threadID: "same")
        var selection = ConversationSelection<ConversationKey>()
        selection.select(a)
        let tokenRequest = selection.beginRemoval(of: a, visibleIDs: [a, b])
        let token = try #require(tokenRequest)
        selection.finishRemoval(token, removed: true, visibleIDs: [b])
        #expect(selection.selectedID == b)
    }
}
