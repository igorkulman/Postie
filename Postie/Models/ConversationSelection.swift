import Foundation

/// Selection belongs to conversations, never to row positions.
struct ConversationSelection<ID: Hashable> {
    private(set) var selectedIDs: Set<ID> = []
    private var selectsInitialConversation = true
    private var revision = 0
    private var removals: [UUID: Removal] = [:]

    private struct Removal {
        let ids: Set<ID>
        let revision: Int
        // In the visible order at action time: older neighbors first, then newer ones.
        let neighbors: [ID]
    }

    /// The conversation to open. Several selected conversations stay closed.
    var selectedID: ID? { selectedIDs.count == 1 ? selectedIDs.first : nil }

    mutating func select(_ id: ID?) {
        select(id.map { [$0] } ?? [])
    }

    mutating func select(_ ids: Set<ID>) {
        selectsInitialConversation = false
        guard selectedIDs != ids else { return }
        selectedIDs = ids
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
            return
        }
        let visible = Set(visibleIDs)
        let missing = selectedIDs.subtracting(visible)
        guard !missing.isEmpty else { return }
        if let removal = removals.values.first(where: { $0.ids == selectedIDs && $0.revision == revision }) {
            // The whole selection is going. Wait for all of it, so that the last row left never opens by itself.
            guard selectedIDs.isDisjoint(with: visible) else { return }
            select(removal.neighbors.first { visible.contains($0) })
        } else {
            // Background disappearance only drops those rows; only an explicit removal advances selection.
            select(selectedIDs.subtracting(missing))
        }
    }

    /// List may emit a smaller selection as selected rows disappear. Apply our policy, not its row fallback.
    mutating func updateFromList(_ ids: Set<ID>, visibleIDs: [ID]) {
        let visible = Set(visibleIDs)
        let stillVisible = selectedIDs.intersection(visible)
        if ids == stillVisible, stillVisible != selectedIDs {
            reconcile(with: visibleIDs)
        } else if ids != selectedIDs, ids.isEmpty || !ids.isDisjoint(with: visible) {
            select(ids.intersection(visible))
        }
    }

    func isRemoving(_ id: ID) -> Bool { removals.values.contains { $0.ids.contains(id) } }

    mutating func beginRemoval(of id: ID, visibleIDs: [ID]) -> UUID? {
        beginRemoval(of: [id], visibleIDs: visibleIDs)
    }

    /// Each operation owns its snapshot; another removal cannot overwrite or clear it.
    mutating func beginRemoval(of ids: Set<ID>, visibleIDs: [ID]) -> UUID? {
        guard ids.allSatisfy({ !isRemoving($0) && visibleIDs.contains($0) }),
              let last = visibleIDs.lastIndex(where: { ids.contains($0) }) else { return nil }
        let token = UUID()
        let neighbors = (Array(visibleIDs.dropFirst(last + 1)) + visibleIDs.prefix(last).reversed()).filter { !ids.contains($0) }
        removals[token] = Removal(ids: ids, revision: revision, neighbors: neighbors)
        return token
    }

    /// Called as each row is removed, before the follow-up refresh can reorder the list. The last row finishes the removal.
    @discardableResult
    mutating func rowRemoved(_ token: UUID, visibleIDs: [ID]) -> Bool {
        guard let removal = removals[token], removal.ids.isDisjoint(with: visibleIDs) else { return false }
        return finishRemoval(token, removed: true, visibleIDs: visibleIDs)
    }

    /// A failed/stale operation only releases its token. User selection changes always win.
    /// Rows Gmail refused stay selected; once none are left, selection moves to the next neighbor.
    @discardableResult
    mutating func finishRemoval(_ token: UUID, removed: Bool, visibleIDs: [ID]) -> Bool {
        guard let removal = removals.removeValue(forKey: token) else { return false }
        guard removed, selectedIDs == removal.ids, revision == removal.revision else { return false }
        let refused = removal.ids.intersection(visibleIDs)
        if refused.isEmpty { select(removal.neighbors.first { visibleIDs.contains($0) }) }
        else { select(refused) }
        return true
    }
}
