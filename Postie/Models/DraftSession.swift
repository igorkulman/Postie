import AppKit
import Foundation
import Observation
import os

/// A draft as Gmail keeps it. The ID stays the same however often the draft is saved.
struct DraftRef: Hashable, Sendable {
    let accountID: String
    let draftID: String
}

/// What the composer needs from the mail store to keep its message as a Gmail draft.
struct DraftStorage {
    var save: @MainActor (ComposeDraft, DraftRef?) async throws -> DraftRef
    var delete: @MainActor (DraftRef) async throws -> Void
    /// A draft can be open in one window only. Claiming it lets another request find that window instead.
    var claim: @MainActor (DraftRef, NSWindow?) -> Void
    var release: @MainActor (DraftRef) -> Void
    var saveLocally: @MainActor (ComposeDraft) async throws -> Void = { _ in }
    var removeLocally: @MainActor (String) async throws -> Void = { _ in }
    var isLocalRecovery: @MainActor (String) -> Bool = { _ in false }
    var claimLocal: @MainActor (String, String?, NSWindow?) -> Void = { _, _, _ in }
    var releaseLocal: @MainActor (String, String?) -> Void = { _, _ in }
}

/// Keeps one composer's message saved as a Gmail draft: saves are queued one after another, so the draft
/// is created once and every later save replaces it, and nothing is saved after the composer is done.
@MainActor
@Observable
final class DraftSession {
    enum State: Equatable {
        case idle, saving, savedLocally
        case saved(Date)
        case failed(String)
    }

    /// The parts of a message that end up in the draft.
    struct Snapshot: Hashable {
        let recipient, cc, bcc, subject, content: String
        let attachments: [URL]
        let accountID: String?

        init(_ draft: ComposeDraft) {
            recipient = draft.recipient
            cc = draft.cc
            bcc = draft.bcc
            subject = draft.subject
            content = draft.html ?? draft.body
            attachments = draft.attachments
            accountID = draft.accountID
        }
    }

    private(set) var state = State.idle
    private(set) var ref: DraftRef?
    @ObservationIgnored private let storage: DraftStorage
    @ObservationIgnored private var lastSaved: Snapshot?
    private var lastLocalSaved: Snapshot?
    private(set) var hasStartedSaving = false
    @ObservationIgnored private var latestSnapshot: Snapshot?
    @ObservationIgnored private var latestDraft: ComposeDraft?
    @ObservationIgnored private var localQueue: Task<Result<Void, Error>, Never>?
    @ObservationIgnored private let localDraftID: String?
    @ObservationIgnored private let localAccountID: String?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var pausesSaves = false
    @ObservationIgnored private weak var window: NSWindow?

    init(storage: DraftStorage, existing: DraftRef? = nil, draftID: String? = nil, accountID: String? = nil) {
        self.storage = storage
        self.localDraftID = draftID
        self.localAccountID = accountID
        ref = existing
    }

    /// Whether the draft in Gmail already has this content.
    func isSaved(_ draft: ComposeDraft) -> Bool { lastSaved == Snapshot(draft) }

    /// A failed Gmail save can still be safely closed if the exact current work is durable on this Mac.
    func isSavedLocally(_ draft: ComposeDraft) -> Bool { lastLocalSaved == Snapshot(draft) }

    /// Notes that Gmail already has this content, as when a draft has just been opened.
    func markSaved(_ draft: ComposeDraft) { lastSaved = Snapshot(draft) }

    /// Tells the store which window shows the draft, so opening it again can bring that window forward.
    func attach(to window: NSWindow?) {
        self.window = window
        if let localDraftID { storage.claimLocal(localDraftID, localAccountID, window) }
        if let ref { storage.claim(ref, window) }
    }

    /// Saves the draft after any save already under way. A caller that stops waiting does not stop the save.
    func save(_ draft: ComposeDraft) async {
        guard !isClosed, !pausesSaves else { return }
        let snapshot = Snapshot(draft)
        hasStartedSaving = true
        latestSnapshot = snapshot
        latestDraft = draft
        state = .saving
        // Disk writes have their own queue: a slow Gmail request must not hold newer work in memory.
        let previousLocal = localQueue
        let localTask = Task<Result<Void, Error>, Never> { [self] in
            _ = await previousLocal?.value
            guard !isClosed else { return .success(()) }
            do {
                var recovery = draft
                // A Gmail draft ID is scoped to its account. Never pair the old account’s ID with a new From address.
                recovery.gmailDraftID = ref.flatMap { $0.accountID == recovery.accountID ? $0.draftID : nil }
                try await storage.saveLocally(recovery)
                lastLocalSaved = snapshot
                return .success(())
            } catch { return .failure(error) }
        }
        localQueue = localTask
        let previous = queue
        let task = Task { [self] in
            await previous?.value
            let localResult = await localTask.value
            await perform(draft, localResult: localResult)
        }
        queue = task
        await task.value
    }

    private func perform(_ draft: ComposeDraft, localResult: Result<Void, Error>) async {
        let snapshot = Snapshot(draft)
        guard !isClosed else { return }
        // Gmail cannot preserve a half-typed address. Keep the exact editor content locally until it can.
        let addresses = [draft.recipient, draft.cc, draft.bcc]
        guard addresses.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || EmailAddresses.isValidList($0) }) else {
            if case .failure(let error) = localResult { state = .failed(error.localizedDescription) }
            else { state = .savedLocally }
            return
        }
        do {
            if snapshot != lastSaved {
                let saved = try await storage.save(draft, ref)
                // The account changed, so the draft now lives in another mailbox and the old copy is gone.
                if ref != saved {
                    if let ref { storage.release(ref) }
                    ref = saved
                    storage.claim(saved, window)
                }
            }
            // Cleanup joins the disk queue too. An older Gmail completion must never erase a newer recovery.
            let previousLocal = localQueue
            let cleanup = Task<Result<Void, Error>, Never> { [self] in
                _ = await previousLocal?.value
                do {
                    if latestSnapshot == snapshot {
                        try await storage.removeLocally(draft.id)
                    } else if var recovery = latestDraft, let ref, recovery.accountID == ref.accountID {
                        // Preserve the new Gmail ID alongside newer unsynced content, even after a crash.
                        recovery.gmailDraftID = ref.draftID
                        try await storage.saveLocally(recovery)
                        lastLocalSaved = Snapshot(recovery)
                    }
                    return .success(())
                } catch { return .failure(error) }
            }
            localQueue = cleanup
            try await cleanup.value.get()
            lastSaved = snapshot
            state = .saved(Date())
        } catch {
            Log.api.error("Saving the draft failed: \(error.localizedDescription, privacy: .public)")
            if case .failure(let localError) = localResult {
                state = .failed(String(localized: "Couldn’t save on this Mac or to Gmail: \(localError.localizedDescription)"))
            } else { state = .failed(error.localizedDescription) }
        }
    }

    /// The draft to send from `accountID`, once everything typed so far is saved. Nil when it must go out as a new message.
    func draftIDForSending(from accountID: String?) async -> String? {
        pausesSaves = true
        await queue?.value
        _ = await localQueue?.value
        guard let ref else { return nil }
        if let accountID, ref.accountID != accountID {
            await deleteSavedCopy()
            return nil
        }
        return ref.draftID
    }

    func resumeSaving() { pausesSaves = false }

    /// The message was sent or the composer was closed: nothing more is saved, and the draft can be opened elsewhere.
    func finish() {
        isClosed = true
        if let ref { storage.release(ref) }
        if let localDraftID { storage.releaseLocal(localDraftID, localAccountID) }
    }

    /// Closes the composer and removes the draft from Gmail.
    func discard() async {
        isClosed = true
        await queue?.value
        _ = await localQueue?.value
        guard await deleteSavedCopy() else { isClosed = false; return }
        if let localDraftID {
            do { try await storage.removeLocally(localDraftID) }
            catch { state = .failed(error.localizedDescription); isClosed = false; return }
            storage.releaseLocal(localDraftID, localAccountID)
        }
        state = .idle
    }

    /// Sending has already durably queued the attachments; a stale recovery copy must not be reopened.
    func removeLocalRecovery(for id: String) async {
        do { try await storage.removeLocally(id) }
        catch { Log.api.error("Removing a queued draft’s recovery copy failed: \(error.localizedDescription, privacy: .public)") }
    }

    @discardableResult
    private func deleteSavedCopy() async -> Bool {
        guard let ref else { return true }
        do { try await storage.delete(ref) }
        catch {
            Log.api.error("Deleting the draft failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return false
        }
        self.ref = nil
        lastSaved = nil
        storage.release(ref)
        return true
    }
}
