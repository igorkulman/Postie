import Foundation

/// Selection belongs to a conversation, never to a row position. Shared by Gmail and sample mail.
struct ConversationSelection<ID: Hashable> {
    private(set) var selectedID: ID?
    private var selectsInitialConversation = true
    private var revision = 0
    private var removals: [UUID: Removal] = [:]

    private struct Removal {
        let id: ID
        let revision: Int
        // In the visible order at action time: older neighbors first, then newer ones.
        let neighbors: [ID]
    }

    mutating func select(_ id: ID?) {
        selectsInitialConversation = false
        guard selectedID != id else { return }
        selectedID = id
        revision += 1
    }

    /// A new folder may initially open its first conversation. Refreshes never do this again.
    mutating func reset() {
        select(nil)
        removals = [:]
        selectsInitialConversation = true
    }

    mutating func reconcile(with visibleIDs: [ID]) {
        if selectsInitialConversation, let first = visibleIDs.first {
            select(first)
        } else if let selectedID, !visibleIDs.contains(selectedID) {
            let removal = removals.values.first { $0.id == selectedID && $0.revision == revision }
            // Background disappearance clears selection; only an explicit removal advances it.
            select(removal?.neighbors.first { visibleIDs.contains($0) })
        }
    }

    /// List may emit a deselection as a selected row disappears. Apply our policy, not its row fallback.
    mutating func updateFromList(_ id: ID?, visibleIDs: [ID]) {
        if id == nil, let selectedID, !visibleIDs.contains(selectedID) {
            reconcile(with: visibleIDs)
        } else if selectedID != id, id == nil || visibleIDs.contains(where: { $0 == id }) {
            select(id)
        }
    }

    func isRemoving(_ id: ID) -> Bool { removals.values.contains { $0.id == id } }

    /// Each operation owns its snapshot; another removal cannot overwrite or clear it.
    mutating func beginRemoval(of id: ID, visibleIDs: [ID]) -> UUID? {
        guard !isRemoving(id), let index = visibleIDs.firstIndex(of: id) else { return nil }
        let token = UUID()
        let neighbors = Array(visibleIDs.dropFirst(index + 1)) + visibleIDs.prefix(index).reversed()
        removals[token] = Removal(id: id, revision: revision, neighbors: neighbors)
        return token
    }

    /// Called as soon as the row is removed, before the follow-up refresh can reorder the list.
    /// A failed/stale operation only releases its token. User selection changes always win.
    @discardableResult
    mutating func finishRemoval(_ token: UUID, removed: Bool, visibleIDs: [ID]) -> Bool {
        guard let removal = removals.removeValue(forKey: token) else { return false }
        guard removed, selectedID == removal.id, revision == removal.revision else { return false }
        select(removal.neighbors.first { visibleIDs.contains($0) })
        return true
    }
}
