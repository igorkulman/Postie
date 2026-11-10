#if DEBUG
import Foundation

nonisolated enum CalendarPreviewData {
    static let invitation = CalendarInvitation(
        uid: "refinement@example.com", title: "[iOS] Refinement Session",
        start: Date(timeIntervalSince1970: 1_792_157_400), end: Date(timeIntervalSince1970: 1_792_161_000),
        isAllDay: false, timeZoneID: "Europe/Prague", location: "Google Meet",
        meetingURL: URL(string: "https://meet.google.com/example"),
        organizer: .init(email: "sam@example.com", name: "Sam Taylor", participation: "ACCEPTED"),
        attendees: [.init(email: "alex@example.com", name: "Alex Morgan", participation: "NEEDS-ACTION"),
                    .init(email: "sam@example.com", name: "Sam Taylor", participation: "ACCEPTED")],
        method: "REQUEST", sequence: 1, isCancelled: false, isRecurring: false, recurrenceID: nil
    )

    static let conversation = GmailConversation(id: "calendar-preview", subject: "Updated invitation: [iOS] Refinement Session", messages: [
        GmailMessage(
            id: "calendar-message", senderName: "Sam Taylor", senderEmail: "sam@example.com", recipient: "alex@example.com", cc: "",
            date: Date(timeIntervalSince1970: 1_792_157_000), snippet: "Our weekly refinement session",
            body: "The meeting time has been updated.\n\nPlease join using the meeting link above.\n\nSee you there!",
            attachments: [MailAttachment(messageID: "calendar-message", partID: "0", attachmentID: "preview", filename: "invite.ics",
                                         mimeType: "text/calendar", size: 500)],
            calendarSources: [CalendarSource(partID: "0", data: Data("""
            BEGIN:VCALENDAR
            VERSION:2.0
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:refinement@example.com
            SEQUENCE:1
            DTSTART;TZID=Europe/Prague:20261016T153000
            DTEND;TZID=Europe/Prague:20261016T163000
            SUMMARY:[iOS] Refinement Session
            LOCATION:Google Meet
            URL:https://meet.google.com/example
            ORGANIZER;CN=Sam Taylor:mailto:sam@example.com
            ATTENDEE;CN=Alex Morgan:mailto:alex@example.com
            ATTENDEE;CN=Sam Taylor;PARTSTAT=ACCEPTED:mailto:sam@example.com
            END:VEVENT
            END:VCALENDAR
            """.utf8), attachment: nil, method: nil)], labelIDs: ["INBOX"]
        )
    ])

    static let cancelled = CalendarInvitation(
        uid: "cancelled@example.com", title: "Team planning", start: nil, end: nil, isAllDay: false,
        timeZoneID: "", location: "", meetingURL: nil,
        organizer: .init(email: "sam@example.com", name: "Sam Taylor", participation: "ACCEPTED"),
        attendees: [], method: "CANCEL", sequence: 2, isCancelled: true, isRecurring: false, recurrenceID: nil
    )
}
#endif
