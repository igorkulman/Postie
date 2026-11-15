import Foundation
import Testing
@testable import Postie

/// Controls only persistence timing; DraftSession owns serialization, recovery and cleanup decisions.
@MainActor
private final class AutosaveStorage {
    var local: ComposeDraft?
    var remote: [ComposeDraft] = []
    var deleted: [DraftRef] = []
    var deleteFails = false
    private var pending: CheckedContinuation<DraftRef, Error>?
    private let events: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() { (events, signal) = AsyncStream.makeStream(of: Void.self) }

    var storage: DraftStorage {
        DraftStorage(
            save: { [self] draft, _ in
                remote.append(draft)
                return try await withCheckedThrowingContinuation { pending = $0; signal.yield() }
            },
            delete: { [self] ref in
                if deleteFails { throw GmailError.http(500) }
                deleted.append(ref)
            },
            claim: { _, _ in }, release: { _ in },
            saveLocally: { [self] draft in local = draft; signal.yield() },
            removeLocally: { [self] _ in local = nil; signal.yield() }
        )
    }

    func waitForRemote(_ count: Int) async {
        var iterator = events.makeAsyncIterator()
        while remote.count < count || pending == nil { _ = await iterator.next() }
    }

    func waitForLocal(subject: String) async {
        var iterator = events.makeAsyncIterator()
        while local?.subject != subject { _ = await iterator.next() }
    }

    func finish(_ result: Result<DraftRef, Error> = .success(DraftRef(accountID: "a", draftID: "d1"))) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@Suite("Draft autosave safety", .timeLimit(.minutes(1)))
@MainActor
struct DraftAutosaveTests {
    private func draft(_ subject: String) -> ComposeDraft {
        ComposeDraft(id: "editor", recipient: "alice@example.com", subject: subject, body: "Text", accountID: "a")
    }

    @Test("Newer work reaches disk during a stalled Gmail save, and an older success cannot erase it")
    func independentLocalPersistence() async throws {
        let storage = AutosaveStorage()
        let session = DraftSession(storage: storage.storage)
        let first = Task { await session.save(draft("First")) }
        await storage.waitForRemote(1)
        let second = Task { await session.save(draft("Second")) }
        await storage.waitForLocal(subject: "Second")
        #expect(session.isSavedLocally(draft("Second")))
        storage.finish()
        await storage.waitForRemote(2)
        #expect(storage.local?.subject == "Second")
        #expect(storage.local?.gmailDraftID == "d1")
        storage.finish()
        await first.value
        await second.value
        #expect(storage.local == nil)
        #expect(session.isSaved(draft("Second")))
    }

    @Test("Reverting to the previously saved content is not lost behind an in-flight newer save")
    func revertWhileSaving() async {
        let storage = AutosaveStorage()
        let session = DraftSession(storage: storage.storage)
        session.markSaved(draft("Original"))
        let edit = Task { await session.save(draft("Changed")) }
        await storage.waitForRemote(1)
        let revert = Task { await session.save(draft("Original")) }
        await storage.waitForLocal(subject: "Original")
        storage.finish()
        await storage.waitForRemote(2)
        #expect(storage.remote.map(\.subject) == ["Changed", "Original"])
        storage.finish()
        await edit.value
        await revert.value
        #expect(session.isSaved(draft("Original")))
    }

    @Test("Incomplete addresses remain recoverable exactly as typed instead of being filtered out by Gmail")
    func incompleteRecipient() async {
        let storage = AutosaveStorage()
        let session = DraftSession(storage: storage.storage)
        var partial = draft("Plans")
        partial.recipient = "alice@"
        await session.save(partial)
        #expect(storage.remote.isEmpty)
        #expect(storage.local?.recipient == "alice@")
        #expect(session.isSavedLocally(partial))
        #expect(!session.isSaved(partial))
        #expect(session.state == .savedLocally)
    }

    @Test("Changing From never stores another account’s Gmail draft ID in local recovery")
    func recoveryAccountIdentity() async {
        let storage = AutosaveStorage()
        let session = DraftSession(storage: storage.storage)
        let first = Task { await session.save(draft("Original account")) }
        await storage.waitForRemote(1)
        storage.finish()
        await first.value
        var moved = draft("Other account")
        moved.accountID = "b"
        let move = Task { await session.save(moved) }
        await storage.waitForRemote(2)
        #expect(storage.local?.accountID == "b")
        #expect(storage.local?.gmailDraftID == nil)
        storage.finish(.failure(GmailError.http(500)))
        await move.value
        #expect(storage.local?.accountID == "b")
        #expect(storage.local?.gmailDraftID == nil)
    }

    @Test("Preparing to send freezes autosave, and a failed send can resume saving")
    func sendingBoundary() async {
        let storage = AutosaveStorage()
        let session = DraftSession(storage: storage.storage)
        let first = Task { await session.save(draft("Ready")) }
        await storage.waitForRemote(1)
        storage.finish()
        await first.value
        #expect(await session.draftIDForSending(from: "a") == "d1")
        await session.save(draft("Late editor callback"))
        #expect(storage.remote.map(\.subject) == ["Ready"])
        session.resumeSaving()
        let retry = Task { await session.save(draft("Keep editing")) }
        await storage.waitForRemote(2)
        storage.finish()
        await retry.value
        #expect(session.isSaved(draft("Keep editing")))
    }

    @Test("A failed discard retains the Gmail identity so retry can delete the same draft")
    func discardRetry() async {
        let storage = AutosaveStorage()
        let ref = DraftRef(accountID: "a", draftID: "d7")
        let session = DraftSession(storage: storage.storage, existing: ref)
        storage.deleteFails = true
        await session.discard()
        #expect(session.ref == ref)
        storage.deleteFails = false
        await session.discard()
        #expect(storage.deleted == [ref])
        #expect(session.ref == nil)
        #expect(session.state == .idle)
    }
}
