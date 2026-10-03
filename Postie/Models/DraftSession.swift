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
}

/// Keeps one composer's message saved as a Gmail draft: saves are queued one after another, so the draft
/// is created once and every later save replaces it, and nothing is saved after the composer is done.
@MainActor
@Observable
final class DraftSession {
    enum State: Equatable {
        case idle, saving
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
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private weak var window: NSWindow?

    init(storage: DraftStorage, existing: DraftRef? = nil) {
        self.storage = storage
        ref = existing
    }

    /// Whether the draft in Gmail already has this content.
    func isSaved(_ draft: ComposeDraft) -> Bool { lastSaved == Snapshot(draft) }

    /// Notes that Gmail already has this content, as when a draft has just been opened.
    func markSaved(_ draft: ComposeDraft) { lastSaved = Snapshot(draft) }

    /// Tells the store which window shows the draft, so opening it again can bring that window forward.
    func attach(to window: NSWindow?) {
        self.window = window
        if let ref { storage.claim(ref, window) }
    }

    /// Saves the draft after any save already under way. A caller that stops waiting does not stop the save.
    func save(_ draft: ComposeDraft) async {
        guard !isClosed else { return }
        let previous = queue
        let task = Task { [self] in
            await previous?.value
            await perform(draft)
        }
        queue = task
        await task.value
    }

    private func perform(_ draft: ComposeDraft) async {
        let snapshot = Snapshot(draft)
        guard !isClosed, snapshot != lastSaved else { return }
        state = .saving
        do {
            let saved = try await storage.save(draft, ref)
            // The account changed, so the draft now lives in another mailbox and the old copy is gone.
            if ref != saved {
                if let ref { storage.release(ref) }
                ref = saved
                storage.claim(saved, window)
            }
            lastSaved = snapshot
            state = .saved(Date())
        } catch {
            Log.api.error("Saving the draft failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// The draft to send from `accountID`, once everything typed so far is saved. Nil when it must go out as a new message.
    func draftIDForSending(from accountID: String?) async -> String? {
        await queue?.value
        guard let ref else { return nil }
        if let accountID, ref.accountID != accountID {
            await deleteSavedCopy()
            return nil
        }
        return ref.draftID
    }

    /// The message was sent or the composer was closed: nothing more is saved, and the draft can be opened elsewhere.
    func finish() {
        isClosed = true
        if let ref { storage.release(ref) }
    }

    /// Closes the composer and removes the draft from Gmail.
    func discard() async {
        isClosed = true
        await queue?.value
        await deleteSavedCopy()
    }

    private func deleteSavedCopy() async {
        guard let ref else { return }
        self.ref = nil
        lastSaved = nil
        storage.release(ref)
        do { try await storage.delete(ref) }
        catch { Log.api.error("Deleting the draft failed: \(error.localizedDescription, privacy: .public)") }
    }
}
