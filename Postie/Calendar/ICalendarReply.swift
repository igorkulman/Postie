import Foundation

nonisolated enum ICalendarReply {
    static func message(for invitation: CalendarInvitation, response: CalendarInvitation.Response, email: String,
                        now: Date = Date()) throws -> OutgoingMessage {
        guard invitation.canRespond(as: email), let attendee = invitation.attendee(for: email),
              let organizer = invitation.organizer else { throw CalendarInvitationError.cannotRespond }
        var lines = ["BEGIN:VCALENDAR", "PRODID:-//Postie//Calendar Reply//EN", "VERSION:2.0", "METHOD:REPLY", "BEGIN:VEVENT",
                     "UID:" + escape(invitation.uid), "DTSTAMP:" + dateValue(now, allDay: false),
                     "SEQUENCE:\(invitation.sequence)", "ORGANIZER:mailto:" + organizer.email,
                     "ATTENDEE;PARTSTAT=\(response.rawValue):mailto:" + attendee.email]
        if let start = invitation.start {
            lines.append("DTSTART" + (invitation.isAllDay ? ";VALUE=DATE:" : ":") + dateValue(start, allDay: invitation.isAllDay))
        }
        if let end = invitation.end {
            lines.append("DTEND" + (invitation.isAllDay ? ";VALUE=DATE:" : ":") + dateValue(end, allDay: invitation.isAllDay))
        }
        if let recurrenceID = invitation.recurrenceID { lines.append(recurrenceID) }
        lines += ["SUMMARY:" + escape(invitation.title), "END:VEVENT", "END:VCALENDAR"]
        let data = Data((lines.map(fold).joined(separator: "\r\n") + "\r\n").utf8)
        return OutgoingMessage(from: email, to: organizer.email, subject: response.status + ": " + invitation.title,
                               body: response.status + ": " + invitation.title + "\n" + invitation.dateSummary,
                               calendarReply: data)
    }

    static func dateValue(_ date: Date, allDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
    }

    /// RFC 5545 folds at 75 octets, never in the middle of a UTF-8 scalar.
    private static func fold(_ line: String) -> String {
        var result = ""
        var bytes = 0
        for scalar in line.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > 75 { result += "\r\n "; bytes = 1 }
            result.unicodeScalars.append(scalar)
            bytes += count
        }
        return result
    }
}
