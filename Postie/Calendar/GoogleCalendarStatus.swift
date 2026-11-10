import Foundation

/// An authoritative snapshot from the receiving account's primary Google Calendar.
nonisolated enum GoogleCalendarStatus: String, Sendable {
    case needsAction
    case accepted
    case tentative
    case declined

    var response: CalendarInvitation.Response? {
        switch self {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        case .needsAction: nil
        }
    }

    var title: String {
        switch self {
        case .needsAction: String(localized: "Not responded")
        default: response?.status ?? ""
        }
    }
}
