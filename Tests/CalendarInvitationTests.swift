import Foundation
import SQLite3
import Testing
@testable import Postie

enum CalendarFixtures {
    static let request = """
    BEGIN:VCALENDAR
    VERSION:2.0
    METHOD:REQUEST
    BEGIN:VEVENT
    UID:refinement@example.com
    DTSTAMP:20261010T080000Z
    SEQUENCE:3
    DTSTART;TZID=Europe/Prague:20261016T153000
    DTEND;TZID=Europe/Prague:20261016T163000
    SUMMARY:Refinement\\, planning
     and review
    LOCATION:Meeting room\\; second floor
    DESCRIPTION:Join here\\nhttps://meet.google.com/abc-defg-hij
    ORGANIZER;CN="Taylor; Sam: Team":mailto:sam@example.com
    ATTENDEE;CN=Alex;PARTSTAT=NEEDS-ACTION:mailto:a@example.com
    ATTENDEE;PARTSTAT=ACCEPTED:mailto:b@example.com
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:Reminder
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    static func parse(_ text: String = request) throws -> CalendarInvitation {
        try #require(ICalendarParser.invitations(from: Data(text.utf8)).first)
    }

    static func message(_ id: String, text: String = request) -> GmailMessage {
        GmailMessage(id: id, senderName: "Sam", senderEmail: "sam@example.com", recipient: "a@example.com", cc: "",
                     date: Date(timeIntervalSince1970: 0), snippet: "Invitation", body: "Original invitation",
                     calendarSources: [CalendarSource(partID: "0", data: Data(text.utf8), attachment: nil, method: nil)],
                     labelIDs: ["INBOX"])
    }
}

@Suite("Calendar invitation parsing")
struct CalendarInvitationTests {
    @Test("Folded text, quoted parameters, guest state and Prague daylight-saving time are preserved")
    func googleInvitation() throws {
        let event = try CalendarFixtures.parse()
        #expect(event.title == "Refinement, planningand review")
        #expect(event.start == ISO8601DateFormatter().date(from: "2026-10-16T13:30:00Z"))
        #expect(event.end == ISO8601DateFormatter().date(from: "2026-10-16T14:30:00Z"))
        #expect(event.location == "Meeting room; second floor")
        #expect(event.meetingURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(event.organizer?.name == "Taylor; Sam: Team")
        #expect(event.attendees.map(\.participation) == ["NEEDS-ACTION", "ACCEPTED"])
        #expect(event.canRespond(as: "A@example.com"))
        #expect(!event.canRespond(as: "outsider@example.com"))
    }

    @Test("All-day end dates are exclusive civil dates, including across a DST change")
    func allDay() throws {
        let text = CalendarFixtures.request
            .replacingOccurrences(of: "DTSTART;TZID=Europe/Prague:20261016T153000", with: "DTSTART;VALUE=DATE:20261024")
            .replacingOccurrences(of: "DTEND;TZID=Europe/Prague:20261016T163000", with: "DTEND;VALUE=DATE:20261027")
        let event = try CalendarFixtures.parse(text)
        #expect(event.isAllDay)
        #expect(event.start == ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        #expect(event.end == ISO8601DateFormatter().date(from: "2026-10-27T00:00:00Z"))
        let reply = try ICalendarReply.message(for: event, response: .accepted, email: "a@example.com")
        let calendar = String(decoding: try #require(reply.calendarReply), as: UTF8.self)
        #expect(calendar.contains("DTSTART;VALUE=DATE:20261024\r\n"))
        #expect(calendar.contains("DTEND;VALUE=DATE:20261027\r\n"))
    }

    @Test("DURATION and occurrence identity survive into replies")
    func occurrence() throws {
        let text = CalendarFixtures.request
            .replacingOccurrences(of: "DTEND;TZID=Europe/Prague:20261016T163000", with: "DURATION:PT1H\nRECURRENCE-ID;TZID=Europe/Prague:20261016T150000")
        let event = try CalendarFixtures.parse(text)
        #expect(event.end?.timeIntervalSince(try #require(event.start)) == 3600)
        let reply = try ICalendarReply.message(for: event, response: .tentative, email: "a@example.com")
        #expect(String(decoding: try #require(reply.calendarReply), as: UTF8.self).contains("RECURRENCE-ID:20261016T130000Z\r\n"))
    }

    @Test("Unknown time zones, invalid dates, reversed ranges and duplicate UIDs do not guess event details", arguments: [
        ("Europe/Prague", "Custom/Unknown"),
        ("20261016T153000", "20260230T153000"),
        ("20261016T163000", "20261016T143000"),
        ("SEQUENCE:3", "SEQUENCE:3\nRECURRENCE-ID;RANGE=THISANDFUTURE:20261016T133000Z"),
        ("UID:refinement@example.com", "UID:refinement@example.com\nUID:another@example.com")
    ])
    func unsupported(replacement: (String, String)) {
        #expect(throws: CalendarInvitationError.self) {
            try CalendarFixtures.parse(CalendarFixtures.request.replacingOccurrences(of: replacement.0, with: replacement.1))
        }
    }

    @Test("Cancellation without dates is readable, but cancellations, replies and published events cannot be answered", arguments: ["CANCEL", "REPLY", "PUBLISH"])
    func nonRequest(method: String) throws {
        var text = CalendarFixtures.request.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:\(method)")
        if method == "CANCEL" {
            text = text.replacingOccurrences(of: "DTSTART;TZID=Europe/Prague:20261016T153000\n", with: "")
                .replacingOccurrences(of: "DTEND;TZID=Europe/Prague:20261016T163000\n", with: "")
        }
        let event = try CalendarFixtures.parse(text)
        #expect(!event.canRespond(as: "a@example.com"))
        #expect(throws: CalendarInvitationError.self) { try ICalendarReply.message(for: event, response: .accepted, email: "a@example.com") }
    }

    @Test("MIME method is a fallback, and unsafe organizer addresses cannot receive responses")
    func fallbackAndUnsafeOrganizer() throws {
        let text = CalendarFixtures.request.replacingOccurrences(of: "METHOD:REQUEST\n", with: "")
            .replacingOccurrences(of: "mailto:sam@example.com", with: "mailto:sam%0D%0ABcc:spy@example.com")
        let event = try #require(ICalendarParser.invitations(from: Data(text.utf8), method: "REQUEST").first)
        #expect(event.method == "REQUEST")
        #expect(event.organizer == nil)
        #expect(!event.canRespond(as: "a@example.com"))
    }

    @Test("Reply MIME carries METHOD=REPLY, original UID and sequence, and only the responding guest", arguments: CalendarInvitation.Response.allCases)
    func reply(response: CalendarInvitation.Response) throws {
        let message = try ICalendarReply.message(for: CalendarFixtures.parse(), response: response, email: "a@example.com",
                                                now: Date(timeIntervalSince1970: 0))
        #expect(message.from == "a@example.com")
        #expect(message.to == "sam@example.com")
        #expect(message.cc.isEmpty && message.bcc.isEmpty)
        let raw = String(decoding: GmailMessageBuilder.rfc822(message), as: UTF8.self)
        #expect(raw.contains("Content-Type: multipart/alternative;"))
        #expect(raw.contains("Content-Type: text/calendar; charset=UTF-8; method=REPLY; component=VEVENT"))
        let encoded = try #require(raw.components(separatedBy: "filename=\"reply.ics\"\r\nContent-Transfer-Encoding: base64\r\n\r\n").last?
            .components(separatedBy: "\r\n--").first)
        let calendar = String(decoding: try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)), as: UTF8.self)
        #expect(calendar.contains("METHOD:REPLY\r\n"))
        #expect(calendar.contains("UID:refinement@example.com\r\n"))
        #expect(calendar.contains("SEQUENCE:3\r\n"))
        #expect(calendar.contains("DTSTAMP:19700101T000000Z\r\n"))
        #expect(calendar.contains("ATTENDEE;PARTSTAT=\(response.rawValue):mailto:a@example.com\r\n"))
        #expect(!calendar.contains("b@example.com"))
        #expect(calendar.contains("DTSTART:20261016T133000Z\r\n"))
    }

    @Test("Reply folding is UTF-8 safe, and escaped text cannot inject calendar properties")
    func foldingAndInjection() throws {
        let title = String(repeating: "🗓", count: 35) + "\\nATTENDEE:mailto:spy@example.com"
        let text = CalendarFixtures.request.replacingOccurrences(of: "SUMMARY:Refinement\\, planning\n and review", with: "SUMMARY:" + title)
        let event = try CalendarFixtures.parse(text)
        let reply = try ICalendarReply.message(for: event, response: .accepted, email: "a@example.com")
        let calendar = String(decoding: try #require(reply.calendarReply), as: UTF8.self)
        #expect(calendar.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let parsed = try #require(ICalendarParser.invitations(from: Data(calendar.utf8)).first)
        #expect(parsed.title == String(repeating: "🗓", count: 35) + "\nATTENDEE:mailto:spy@example.com")
        #expect(parsed.attendees.map(\.email) == ["a@example.com"])
    }
}

@Suite("Calendar mail integration", .timeLimit(.minutes(1)))
struct CalendarMailTests {
    @Test("Inline alternatives and unnamed downloadable calendars are found; forwarded messages are excluded")
    func mimeSources() throws {
        let inline: [String: Any] = ["partId": "0", "mimeType": "text/calendar", "body": ["data": GmailMessageBuilder.base64URL(Data(CalendarFixtures.request.utf8))]]
        let file: [String: Any] = ["partId": "1", "mimeType": "text/calendar", "body": ["attachmentId": "A", "size": 500]]
        let forwarded: [String: Any] = ["partId": "2", "mimeType": "message/rfc822", "parts": [inline]]
        let payload: [String: Any] = ["mimeType": "multipart/mixed", "parts": [inline, file, forwarded]]
        let resource = try JSONDecoder().decode(GmailThreadResource.Part.self, from: JSONSerialization.data(withJSONObject: payload))
        let sources = resource.calendarSources(messageID: "m")
        #expect(sources.count == 2)
        #expect(sources[0].data == Data(CalendarFixtures.request.utf8))
        #expect(sources[1].attachment?.filename == "invite.ics")
        #expect(sources[1].attachment?.messageID == "m")
        #expect(sources[1].attachment?.attachmentID == "A")
    }

    @Test("Calendar bytes survive cache reopening and metadata refreshes without losing the display projection")
    @MainActor
    func cache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        let account = CachedGmailAccount(id: "a", email: "a@example.com")
        let full = GmailConversation(id: "t", subject: "Invitation", messages: [CalendarFixtures.message("m")])
        do {
            let cache = try await GmailCache.open(at: url)
            let session = try await cache.session(for: account)
            try await session.saveConversation(full)
            var metadata = full.messages[0]
            metadata.bodyLoaded = false
            metadata.calendarSources = [CalendarSource(partID: "0", data: nil, attachment: nil, method: nil)]
            try await session.saveConversation(GmailConversation(id: "t", subject: "Invitation", messages: [metadata]))
        }
        let cache = try await GmailCache.open(at: url)
        let session = try await cache.session(for: account)
        let restored = try #require(try await session.conversation(id: "t"))
        #expect(restored.messages[0].calendarSources == full.messages[0].calendarSources)
        let display = restored.presentation(includingBodies: true)
        #expect(display.messages[0].calendarSources == full.messages[0].calendarSources)
    }

    @Test("Cached Archive invitations without calendar metadata reach the card without re-downloading the message")
    @MainActor
    func cachedArchiveInvitation() async throws {
        for file in [("INVITE.ICS", "application/octet-stream"), ("event", "text/calendar")] {
            try await checkCachedArchiveInvitation(file: file)
        }
    }

    @MainActor
    private func checkCachedArchiveInvitation(file: (String, String)) async throws {
        let attachment = MailAttachment(messageID: "m", partID: "1", attachmentID: "old-attachment", filename: file.0,
                                        mimeType: file.1, size: 500)
        let unrelated = MailAttachment(messageID: "m", partID: "2", attachmentID: "pdf", filename: "agenda.pdf",
                                       mimeType: "application/pdf", size: 100)
        // Before calendar support, loaded messages retained attachments but had no calendar sources.
        var message = CalendarFixtures.message("m")
        message.calendarSources = []
        message.attachments = [attachment, unrelated]
        message.labelIDs = []
        let cached = GmailConversation(id: "t", subject: "Archived invitation", messages: [message])
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mail.sqlite")
        let cache = try await GmailCache.open(at: url)
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        _ = try await session.savePage(GmailPage(conversations: [cached], nextPageToken: nil), mailbox: .archive, refreshing: true)
        // The calendar migration adds a nullable column. Existing rows have SQL NULL,
        // unlike new messages explicitly scanned and found to have no calendar parts.
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "UPDATE messages SET calendarSources = NULL", nil, nil, nil) == SQLITE_OK)
        let api = StubAPI([])
        api.failsSelection = true
        let reader = GmailReaderStore(api: api, mailbox: .archive, cache: session)
        await reader.restoreCachedMailbox()
        await reader.select("t")
        let selected = try #require(reader.selectedConversation)
        let displayed = selected.presentation(includingBodies: true, mailbox: .archive)
        #expect(displayed.messages[0].calendarSources.map(\.attachment) == [attachment])
        #expect(displayed.messages[0].body == "Original invitation")
        #expect(displayed.messages[0].attachments == [attachment, unrelated])
        #expect(api.selected.isEmpty)
        #expect(reader.conversationError == nil)
    }

    @Test("Explicitly excluded calendar parts stay excluded after caching, including files inside forwarded mail")
    func excludedCalendarAttachment() async throws {
        var message = CalendarFixtures.message("m")
        message.calendarSources = []
        message.attachments = [MailAttachment(messageID: "m", partID: "1.0", attachmentID: "forwarded", filename: "invite.ics",
                                              mimeType: "text/calendar", size: 500)]
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        try await session.saveConversation(GmailConversation(id: "t", subject: "Forwarded email", messages: [message]))
        let restored = try #require(try await session.conversation(id: "t"))
        #expect(restored.messages[0].calendarSources.isEmpty)
    }

    @Test("Newer updates and whole-event cancellations disable older responses, but another event does not")
    @MainActor
    func superseded() async throws {
        let first = CalendarFixtures.message("m1")
        let newer = CalendarFixtures.message("m2", text: CalendarFixtures.request.replacingOccurrences(of: "SEQUENCE:3", with: "SEQUENCE:4"))
        let unrelated = CalendarFixtures.message("m3", text: CalendarFixtures.request.replacingOccurrences(of: "refinement@example.com", with: "other@example.com"))
        let mail = GmailConversation(id: "t", subject: "Invitation", messages: [first, newer, unrelated])
        let hub = await MailHubTests().makeHub(["a": HubAPI([mail])])
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        await model.load(mail)
        let oldEvent = try #require(model.invitations["m1"]?.first)
        let newEvent = try #require(model.invitations["m2"]?.first)
        #expect(model.isSuperseded(oldEvent, messageID: "m1"))
        #expect(!model.isSuperseded(newEvent, messageID: "m2"))
        #expect(!model.canRespond(to: oldEvent, messageID: "m1"))
        #expect(model.canRespond(to: newEvent, messageID: "m2"))
        let cancelled = CalendarFixtures.message("m4", text: CalendarFixtures.request.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
            .replacingOccurrences(of: "SEQUENCE:3", with: "SEQUENCE:5"))
        await model.load(GmailConversation(id: "t", subject: "Invitation", messages: [first, newer, unrelated, cancelled]))
        #expect(model.isSuperseded(newEvent, messageID: "m2"))
        #expect(!model.canRespond(to: newEvent, messageID: "m2"))
        await model.load(GmailConversation(id: "t", subject: "Invitation", messages: [unrelated]))
        #expect(!model.canRespond(to: newEvent, messageID: "m2"), "A removed invitation cannot be sent by a stale button action")
    }

    @Test("An unreadable newer invitation blocks stale replies; fixing the source clears the error")
    @MainActor
    func unreadableUpdate() async throws {
        let first = CalendarFixtures.message("m1")
        let broken = CalendarFixtures.message("m2", text: "not a calendar")
        let mail = GmailConversation(id: "t", subject: "Invitation", messages: [first, broken])
        let hub = await MailHubTests().makeHub(["a": HubAPI([mail])])
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        await model.load(mail)
        let event = try #require(model.invitations["m1"]?.first)
        #expect(model.errors["m2"] != nil)
        #expect(!model.canRespond(to: event, messageID: "m1"))
        let fixed = CalendarFixtures.message("m2", text: CalendarFixtures.request.replacingOccurrences(of: "SEQUENCE:3", with: "SEQUENCE:4"))
        await model.load(GmailConversation(id: "t", subject: "Invitation", messages: [first, fixed]))
        #expect(model.errors.isEmpty)
        let updated = try #require(model.invitations["m2"]?.first)
        #expect(model.canRespond(to: updated, messageID: "m2"))
        #expect(!model.canRespond(to: event, messageID: "m1"))
    }

    @Test("RSVP goes through the receiving account, not the default; failure never records a sent reply")
    @MainActor
    func routingAndFailure() async throws {
        let event = try CalendarFixtures.parse()
        let a = HubAPI([])
        let b = HubAPI([])
        let hub = await MailHubTests().makeHub(["a": a, "b": b])
        let key = ConversationKey(accountID: "b", threadID: "t")
        try await hub.sendCalendarResponse(.tentative, to: event, key: key)
        #expect(await a.sent.isEmpty)
        let sent = try #require(await b.sent.first)
        #expect(sent.from == "b@example.com")
        #expect(sent.to == "sam@example.com")
        #expect(hub.calendarResponses[CalendarResponseKey(accountID: "b", invitation: event)] == .tentative)
        #expect(hub.calendarResponses[CalendarResponseKey(accountID: "a", invitation: event)] == nil)
        await a.failSending(.http(403))
        await #expect(throws: GmailError.http(403)) {
            try await hub.sendCalendarResponse(.accepted, to: event, key: ConversationKey(accountID: "a", threadID: "t"))
        }
        #expect(hub.calendarResponses[CalendarResponseKey(accountID: "a", invitation: event)] == nil)
        #expect(hub.calendarRepliesInFlight.isEmpty)
    }
}
