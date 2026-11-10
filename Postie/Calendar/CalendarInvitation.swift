import Foundation

nonisolated struct CalendarInvitation: Equatable, Sendable, Identifiable {
    struct Person: Equatable, Sendable {
        let email: String
        let name: String
        let participation: String

        var displayName: String { name.isEmpty ? email : name }
    }

    enum Response: String, CaseIterable, Sendable {
        case accepted = "ACCEPTED"
        case tentative = "TENTATIVE"
        case declined = "DECLINED"

        var title: String {
            switch self {
            case .accepted: String(localized: "Accept")
            case .tentative: String(localized: "Maybe")
            case .declined: String(localized: "Decline")
            }
        }

        var status: String {
            switch self {
            case .accepted: String(localized: "Accepted")
            case .tentative: String(localized: "Tentative")
            case .declined: String(localized: "Declined")
            }
        }
    }

    let uid: String
    let title: String
    let start: Date?
    let end: Date?
    let isAllDay: Bool
    let timeZoneID: String
    let location: String
    let meetingURL: URL?
    let organizer: Person?
    let attendees: [Person]
    let method: String
    let sequence: Int
    let isCancelled: Bool
    let isRecurring: Bool
    /// Kept as an iCalendar date property, including its value type, for an occurrence reply.
    let recurrenceID: String?

    var eventKey: String { uid + "\u{0}" + (recurrenceID ?? "") }
    var id: String { eventKey + "\u{0}" + String(sequence) + "\u{0}" + method }

    func attendee(for email: String) -> Person? {
        attendees.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    func canRespond(as email: String) -> Bool {
        method == "REQUEST" && !isCancelled && organizer != nil && attendee(for: email) != nil
            && organizer?.email.caseInsensitiveCompare(email) != .orderedSame
    }

    /// Calendar dates are civil dates, not instants in the reader's time zone.
    var dateSummary: String {
        guard let start else { return String(localized: "Date not provided") }
        let zone = isAllDay ? TimeZone(secondsFromGMT: 0)! : .current
        let dateStyle = Date.FormatStyle(date: .complete, time: .omitted, timeZone: zone)
        if isAllDay {
            let lastDay = (end ?? start).addingTimeInterval(-86_400)
            let dates = lastDay > start ? start.formatted(dateStyle) + " – " + lastDay.formatted(dateStyle) : start.formatted(dateStyle)
            return dates + " · " + String(localized: "All day")
        }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        let summary: String
        if let end, end > start, Calendar.current.isDate(start, inSameDayAs: end) {
            summary = start.formatted(dateStyle) + "\n" + start.formatted(timeStyle) + " – " + end.formatted(timeStyle)
        } else {
            summary = end.flatMap { $0 > start ? start.formatted(style) + " – " + $0.formatted(style) : nil } ?? start.formatted(style)
        }
        return summary + " · " + (TimeZone.current.abbreviation(for: start) ?? TimeZone.current.identifier)
    }
}

nonisolated enum CalendarInvitationError: LocalizedError {
    case unsupported
    case cannotRespond

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Postie cannot display this calendar invitation. Use the original email or calendar attachment below.")
        case .cannotRespond: String(localized: "This invitation cannot be answered from this account, or a newer invitation is available.")
        }
    }
}
