import Foundation

/// Only the fields needed to match an invitation and read the calendar owner's response.
nonisolated struct GoogleCalendarEvents: Decodable, Sendable {
    struct Event: Decodable, Sendable {
        struct Attendee: Decodable, Sendable {
            let isSelf: Bool?
            let responseStatus: String?
            enum CodingKeys: String, CodingKey {
                case isSelf = "self"
                case responseStatus
            }
        }

        struct OriginalStart: Decodable, Sendable {
            let date: String?
            let dateTime: String?
            let timeZone: String?

            var recurrenceID: String? {
                if let date { return "RECURRENCE-ID;VALUE=DATE:" + date.replacingOccurrences(of: "-", with: "") }
                guard let dateTime else { return nil }
                let iso = ISO8601DateFormatter()
                var parsed = iso.date(from: dateTime)
                if parsed == nil {
                    iso.formatOptions.insert(.withFractionalSeconds)
                    parsed = iso.date(from: dateTime)
                }
                if parsed == nil, let timeZone, let zone = TimeZone(identifier: timeZone) {
                    let local = DateFormatter()
                    local.locale = Locale(identifier: "en_US_POSIX")
                    local.calendar = Calendar(identifier: .gregorian)
                    local.timeZone = zone
                    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    local.isLenient = false
                    parsed = local.date(from: dateTime)
                }
                return parsed.map { "RECURRENCE-ID:" + ICalendarReply.dateValue($0, allDay: false) }
            }
        }

        let iCalUID: String?
        let sequence: Int?
        let recurringEventId: String?
        let originalStartTime: OriginalStart?
        let recurrence: [String]?
        let attendees: [Attendee]?
    }

    let items: [Event]?
    let nextPageToken: String?

    static func status(for invitation: CalendarInvitation, in events: [Event]) -> GoogleCalendarStatus? {
        let matching = events.filter { $0.iCalUID == invitation.uid }
        let masters = matching.filter { $0.recurringEventId == nil && $0.originalStartTime == nil }
        let candidates: [Event]
        if let recurrenceID = invitation.recurrenceID {
            let occurrences = matching.filter { $0.originalStartTime?.recurrenceID == recurrenceID }
            // An unchanged occurrence inherits the series response, not a neighboring occurrence's.
            candidates = occurrences.isEmpty ? masters.filter { !($0.recurrence ?? []).isEmpty } : occurrences
        } else {
            candidates = masters
        }
        guard candidates.count == 1, let event = candidates.first,
              event.sequence.map({ $0 >= invitation.sequence }) ?? true else { return nil }
        // On the owner's calendar, a deleted invitation can be marked cancelled even
        // though the organizer did not cancel it. Read the actual guest response, not that flag.
        let owner = (event.attendees ?? []).filter { $0.isSelf == true }
        guard owner.count == 1, let response = owner.first?.responseStatus else { return nil }
        return GoogleCalendarStatus(rawValue: response)
    }
}
