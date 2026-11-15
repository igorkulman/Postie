import Foundation
import Observation

nonisolated struct MailRemovalReceipt: Sendable {
    let key: ConversationKey
    let archiving: Bool
    let labels: Set<String>
}

/// One accepted action (possibly a batch). Both the banner and Edit > Undo use this same operation.
@MainActor
@Observable
final class MailRemovalUndo {
    let id = UUID()
    let archiving: Bool
    let count: Int
    private(set) var isRestoring = false
    private(set) var error: String?
    private var remaining: [MailRemovalReceipt]
    @ObservationIgnored private let hub: MailHub
    @ObservationIgnored private weak var manager: UndoManager?

    init(receipts: [MailRemovalReceipt], hub: MailHub) {
        remaining = receipts
        archiving = receipts.first?.archiving ?? true
        count = receipts.count
        self.hub = hub
    }

    var canUndo: Bool { !remaining.isEmpty && !isRestoring }
    var isUndone: Bool { remaining.isEmpty }
    var actionName: String { archiving ? String(localized: "Archive") : String(localized: "Move to Trash") }
    var confirmation: String {
        if isUndone { return String(localized: "Action undone") }
        if let error { return String(localized: "Couldn’t undo: \(error)") }
        if archiving {
            return count == 1 ? String(localized: "Conversation archived") : String(localized: "\(count) conversations archived")
        }
        return count == 1 ? String(localized: "Conversation moved to Trash") : String(localized: "\(count) conversations moved to Trash")
    }

    func register(with manager: UndoManager?) {
        self.manager = manager
        guard canUndo, let manager else { return }
        manager.registerUndo(withTarget: self) { target in target.undo() }
        manager.setActionName(actionName)
    }

    @discardableResult
    func undo() -> Task<Void, Never>? {
        guard canUndo else { return nil }
        isRestoring = true
        error = nil
        manager?.removeAllActions(withTarget: self)
        let restoration = hub.restoreRemovals(remaining)
        return Task {
            let failures = await restoration.value
            remaining = failures.map(\.receipt)
            error = failures.first?.error
            isRestoring = false
            // Failed inverses remain retryable; successful items are never sent twice.
            if !failures.isEmpty { register(with: manager) }
        }
    }
}
