import Foundation

/// Session-local receipts: these say a reply was sent, not that a remote calendar was updated.
nonisolated struct CalendarResponseKey: Hashable, Sendable {
    let accountID: String
    let event: String
    let organizer: String
    let sequence: Int

    init(accountID: String, invitation: CalendarInvitation) {
        self.accountID = accountID
        event = invitation.eventKey
        organizer = invitation.organizer?.email.lowercased() ?? ""
        sequence = invitation.sequence
    }
}
