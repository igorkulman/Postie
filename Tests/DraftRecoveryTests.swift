import Foundation
import Testing
@testable import Postie

@Suite("Local draft recovery", .timeLimit(.minutes(1)))
@MainActor
struct DraftRecoveryTests {
    @Test("Unsynced text and attachments survive reopening the hub and can be edited from Drafts")
    func reopen() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "notes.txt")
        try Data("Important attachment".utf8).write(to: source)
        let store = DraftRecoveryStore(root: root.appending(path: "recovery"))
        let accounts = await MailHubTests().makeHub(["a": HubAPI([])]).accounts
        let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false, recoveryStore: store) { _ in HubAPI([]) }
        await hub.prepare()
        await hub.reconcile()
        let draft = ComposeDraft(recipient: "alice@", subject: "Do not lose", body: "Offline work", attachments: [source], accountID: "a")
        let session = DraftSession(storage: hub.draftStorage, draftID: draft.id, accountID: "a")
        await session.save(draft)
        #expect(session.isSavedLocally(draft))
        session.finish()
        try FileManager.default.removeItem(at: source)

        let reopened = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false, recoveryStore: store) { _ in HubAPI([]) }
        await reopened.prepare()
        await reopened.reconcile()
        reopened.changeMailbox(.drafts)
        let key = try #require(reopened.conversationKeys.first)
        #expect(reopened.canEditDraft(key))
        let recovered = try #require(try await reopened.openDraft(key))
        #expect(recovered.recipient == "alice@")
        #expect(recovered.subject == "Do not lose")
        #expect(recovered.body == "Offline work")
        let attachment = try #require(recovered.attachments.first)
        #expect(try String(contentsOf: attachment, encoding: .utf8) == "Important attachment")
        // Open editors own independent copies, so syncing/removing recovery cannot invalidate their attachments.
        try await reopened.removeLocalDraft(draft.id)
        #expect(try String(contentsOf: attachment, encoding: .utf8) == "Important attachment")
    }

    @Test("An attachment-copy failure leaves the previous durable snapshot intact")
    func atomicReplacement() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftRecoveryStore(root: root)
        try await store.save(id: "draft", payload: Data("Previous work".utf8), attachments: [])
        await #expect(throws: (any Error).self) {
            try await store.save(id: "draft", payload: Data("New work".utf8), attachments: [root.appending(path: "missing.txt")])
        }
        let entries = try await store.all()
        #expect(entries.count == 1)
        #expect(entries.first?.payload == Data("Previous work".utf8))
    }
}
