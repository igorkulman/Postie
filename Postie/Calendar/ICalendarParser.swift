import Foundation

/// Deliberately bounded iCalendar support, not a calendar engine. Unknown time zones and
/// malformed events fall back to the original message instead of showing a guessed time.
nonisolated enum ICalendarParser {
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    static func invitations(from data: Data, method fallbackMethod: String? = nil) throws -> [CalendarInvitation] {
        guard data.count <= CalendarSource.maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw CalendarInvitationError.unsupported
        }
        let lines = unfold(text)
        guard lines.first?.uppercased() == "BEGIN:VCALENDAR", lines.last?.uppercased() == "END:VCALENDAR" else {
            throw CalendarInvitationError.unsupported
        }
        var stack: [String] = []
        var method = fallbackMethod ?? "PUBLISH"
        var event: [Property] = []
        var events: [[Property]] = []
        for line in lines {
            guard let property = property(line) else { throw CalendarInvitationError.unsupported }
            if property.name == "BEGIN" {
                stack.append(property.value.uppercased())
                if stack == ["VCALENDAR", "VEVENT"] { event = [] }
            } else if property.name == "END" {
                guard stack.last == property.value.uppercased() else { throw CalendarInvitationError.unsupported }
                if stack == ["VCALENDAR", "VEVENT"] { events.append(event) }
                stack.removeLast()
            } else if stack == ["VCALENDAR"] && property.name == "METHOD" {
                method = property.value.uppercased()
            } else if stack == ["VCALENDAR", "VEVENT"] {
                event.append(property)
            }
        }
        guard stack.isEmpty, !events.isEmpty, events.count <= 100 else { throw CalendarInvitationError.unsupported }
        return try events.map { try invitation($0, method: method) }
    }

    private static func invitation(_ properties: [Property], method: String) throws -> CalendarInvitation {
        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        // Duplicate identity/date fields are ambiguous and must not produce an RSVP.
        for name in ["UID", "DTSTART", "DTEND", "ORGANIZER", "RECURRENCE-ID", "SEQUENCE"] {
            guard properties.filter({ $0.name == name }).count <= 1 else { throw CalendarInvitationError.unsupported }
        }
        guard let uid = first("UID").map({ unescape($0.value) }), !uid.isEmpty else { throw CalendarInvitationError.unsupported }
        let cancelled = method == "CANCEL" || first("STATUS")?.value.uppercased() == "CANCELLED"
        let startProperty = first("DTSTART")
        let start = try startProperty.map(date)
        guard start != nil || cancelled else { throw CalendarInvitationError.unsupported }
        let allDay = startProperty?.parameters["VALUE"]?.uppercased() == "DATE"
        let end: Date?
        if let property = first("DTEND") {
            guard (property.parameters["VALUE"]?.uppercased() == "DATE") == allDay else { throw CalendarInvitationError.unsupported }
            end = try date(property)
        } else if let duration = first("DURATION"), let start {
            // Calendar-day/week durations on timed events need DST-aware arithmetic; leave those to a calendar app.
            end = start.addingTimeInterval(try durationSeconds(duration.value, allDay: allDay))
        } else {
            end = start.map { allDay ? $0.addingTimeInterval(86_400) : $0 }
        }
        if let start, let end, end < start || (allDay && end == start) { throw CalendarInvitationError.unsupported }
        let sequence = first("SEQUENCE")?.value ?? "0"
        guard let sequence = Int(sequence), sequence >= 0 else { throw CalendarInvitationError.unsupported }
        let recurrence = try first("RECURRENCE-ID").map { property in
            guard property.parameters["RANGE"] == nil else { throw CalendarInvitationError.unsupported }
            let parsed = try date(property)
            return "RECURRENCE-ID" + (property.parameters["VALUE"]?.uppercased() == "DATE" ? ";VALUE=DATE:" : ":")
                + ICalendarReply.dateValue(parsed, allDay: property.parameters["VALUE"]?.uppercased() == "DATE")
        }
        let location = first("LOCATION").map { unescape($0.value) } ?? ""
        let description = first("DESCRIPTION").map { unescape($0.value) } ?? ""
        let urls = [first("URL")?.value, first("X-GOOGLE-CONFERENCE")?.value, location, description].compactMap { $0 }
        let meetingURL = urls.lazy.compactMap(webURL).first
        return CalendarInvitation(
            uid: uid, title: first("SUMMARY").map { unescape($0.value) } ?? String(localized: "Untitled event"),
            start: start, end: end, isAllDay: allDay, timeZoneID: startProperty?.parameters["TZID"] ?? "",
            location: location, meetingURL: meetingURL, organizer: first("ORGANIZER").flatMap(person),
            attendees: properties.filter { $0.name == "ATTENDEE" }.compactMap(person), method: method, sequence: sequence,
            isCancelled: cancelled, isRecurring: first("RRULE") != nil || first("RDATE") != nil, recurrenceID: recurrence
        )
    }

    private static func person(_ property: Property) -> CalendarInvitation.Person? {
        guard property.value.lowercased().hasPrefix("mailto:"),
              let email = String(property.value.dropFirst(7)).removingPercentEncoding, validEmail(email) else { return nil }
        return CalendarInvitation.Person(email: email, name: property.parameters["CN"].map(unescape) ?? "",
                                         participation: property.parameters["PARTSTAT"]?.uppercased() ?? "NEEDS-ACTION")
    }

    static func validEmail(_ value: String) -> Bool {
        !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
            && value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#,
                    options: .regularExpression) != nil
    }

    private static func date(_ property: Property) throws -> Date {
        let allDay = property.parameters["VALUE"]?.uppercased() == "DATE"
        let utc = property.value.hasSuffix("Z")
        let zone: TimeZone
        if allDay || utc { zone = TimeZone(secondsFromGMT: 0)! }
        else if let id = property.parameters["TZID"] {
            guard let known = TimeZone(identifier: id) else { throw CalendarInvitationError.unsupported }
            zone = known
        } else { zone = .current }
        let format = allDay ? "yyyyMMdd" : (utc ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: property.value), formatter.string(from: date) == property.value else {
            throw CalendarInvitationError.unsupported
        }
        return date
    }

    private static func durationSeconds(_ value: String, allDay: Bool) throws -> TimeInterval {
        let pattern = allDay ? #"^P(?:(\d+)W|(?:(\d+)D))$"# : #"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            throw CalendarInvitationError.unsupported
        }
        func number(_ index: Int) -> Double {
            Range(match.range(at: index), in: value).flatMap { Double(value[$0]) } ?? 0
        }
        let seconds = allDay ? (number(1) * 7 + number(2)) * 86_400 : number(1) * 3600 + number(2) * 60 + number(3)
        guard seconds.isFinite, seconds > 0, seconds <= 366 * 86_400 else { throw CalendarInvitationError.unsupported }
        return seconds
    }

    private static func webURL(_ text: String) -> URL? {
        guard let range = text.range(of: #"https?://[^\s<>\"\\]+"#, options: [.regularExpression, .caseInsensitive]),
              let url = URL(string: String(text[range])), url.host != nil else { return nil }
        return url
    }

    private static func unfold(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else if !line.isEmpty { result.append(line) }
        }
        return result
    }

    /// Split only outside quoted parameter values (CN="Doe; Jane: Team").
    private static func split(_ value: String, on separator: Character, once: Bool = false) -> [String] {
        var quoted = false
        var result = [""]
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == separator && !quoted && (!once || result.count == 1) { result.append("") }
            else { result[result.count - 1].append(character) }
        }
        return result
    }

    private static func property(_ line: String) -> Property? {
        let pair = split(line, on: ":", once: true)
        guard pair.count == 2 else { return nil }
        let fields = split(pair[0], on: ";")
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            let parameter = split(field, on: "=", once: true)
            guard parameter.count == 2 else { return nil }
            parameters[parameter[0].uppercased()] = parameter[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Property(name: fields[0].uppercased(), parameters: parameters, value: pair[1])
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped { result.append(character == "n" || character == "N" ? "\n" : character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
}
