import Foundation
import Testing
@testable import Postie

private actor CalendarStatusTransport: GmailTransport {
    private var replies: [GmailHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ json: [String], status: Int = 200) {
        replies = json.map { GmailHTTPResponse(data: Data($0.utf8), statusCode: status) }
    }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }
}

@Suite("Google Calendar response lookup", .timeLimit(.minutes(1)))
struct GoogleCalendarTests {
    @Test("Lookup uses an authenticated read of the primary calendar, exact UID, pagination, and the owner's response")
    func lookupContract() async throws {
        let event = try CalendarFixtures.parse(CalendarFixtures.request.replacingOccurrences(of: "refinement@example.com", with: "invite+123@example.com"))
        let transport = CalendarStatusTransport([
            #"{"items":[{"iCalUID":"unrelated@example.com","attendees":[{"self":true,"responseStatus":"accepted"}]}],"nextPageToken":"next +/="}"#,
            #"{"items":[{"iCalUID":"invite+123@example.com","sequence":3,"attendees":[{"self":false,"responseStatus":"accepted"},{"self":true,"responseStatus":"declined"}]}]}"#
        ])
        let api = GmailAPI(transport: transport, retryDelays: []) { "calendar-token" }
        #expect(try await api.calendarStatus(for: event) == .declined)
        let requests = await transport.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        #expect(first.httpMethod == "GET")
        #expect(first.url?.host == "www.googleapis.com")
        #expect(first.url?.path == "/calendar/v3/calendars/primary/events")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer calendar-token")
        let firstURL = try #require(first.url)
        let query = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "iCalUID" }?.value == "invite+123@example.com")
        #expect(first.url?.absoluteString.contains("%2B") == true)
        #expect(query.first { $0.name == "singleEvents" }?.value == "false")
        #expect(query.first { $0.name == "showHiddenInvitations" }?.value == "true")
        let lastURL = try #require(requests.last?.url)
        let secondQuery = try #require(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(secondQuery.first { $0.name == "pageToken" }?.value == "next +/=")
    }

    @Test("Moved occurrences match originalStartTime, while series cards ignore occurrence-only responses")
    func recurringOccurrence() async throws {
        let event = try CalendarFixtures.parse(CalendarFixtures.request.replacingOccurrences(of: "SEQUENCE:3", with: "SEQUENCE:3\nRECURRENCE-ID;TZID=Europe/Prague:20261016T153000"))
        let json = #"{"items":[{"iCalUID":"refinement@example.com","sequence":3,"recurrence":["RRULE:FREQ=WEEKLY"],"attendees":[{"self":true,"responseStatus":"accepted"}]},{"iCalUID":"refinement@example.com","sequence":3,"recurringEventId":"series","originalStartTime":{"dateTime":"2026-10-23T15:30:00+02:00"},"attendees":[{"self":true,"responseStatus":"tentative"}]},{"iCalUID":"refinement@example.com","sequence":3,"recurringEventId":"series","originalStartTime":{"dateTime":"2026-10-16T15:30:00+02:00"},"attendees":[{"self":true,"responseStatus":"declined"}]}]}"#
        let api = GmailAPI(transport: CalendarStatusTransport([json])) { "token" }
        #expect(try await api.calendarStatus(for: event) == .declined)
        #expect(try await api.calendarStatus(for: CalendarFixtures.parse()) == .accepted)
        let inherited = json.replacingOccurrences(of: "2026-10-16T15:30:00+02:00", with: "2026-10-30T15:30:00+02:00")
        let series = GmailAPI(transport: CalendarStatusTransport([inherited])) { "token" }
        #expect(try await series.calendarStatus(for: event) == .accepted)
    }

    @Test("All-day occurrences match their civil date; removed exceptions neither inherit nor erase a guest's response")
    func removedAllDayOccurrence() async throws {
        let text = CalendarFixtures.request
            .replacingOccurrences(of: "DTSTART;TZID=Europe/Prague:20261016T153000", with: "DTSTART;VALUE=DATE:20261016\nRECURRENCE-ID;VALUE=DATE:20261016")
            .replacingOccurrences(of: "DTEND;TZID=Europe/Prague:20261016T163000", with: "DTEND;VALUE=DATE:20261017")
        let json = #"{"items":[{"iCalUID":"refinement@example.com","recurrence":["RRULE:FREQ=WEEKLY"],"attendees":[{"self":true,"responseStatus":"accepted"}]},{"iCalUID":"refinement@example.com","recurringEventId":"series","originalStartTime":{"date":"2026-10-16"},"status":"cancelled"}]}"#
        let api = GmailAPI(transport: CalendarStatusTransport([json])) { "token" }
        #expect(try await api.calendarStatus(for: CalendarFixtures.parse(text)) == nil)
        let declinedJSON = json.replacingOccurrences(of: "\"status\":\"cancelled\"", with: "\"status\":\"cancelled\",\"attendees\":[{\"self\":true,\"responseStatus\":\"declined\"}]")
        let declined = GmailAPI(transport: CalendarStatusTransport([declinedJSON])) { "token" }
        #expect(try await declined.calendarStatus(for: CalendarFixtures.parse(text)) == .declined)
    }

    @Test("Missing, ambiguous, outdated, or another guest's data is unknown, never assumed to mean accepted or not responded")
    func unknownResponses() async throws {
        let payloads = [
            #"{"items":[]}"#,
            #"{"items":[{"iCalUID":"refinement@example.com","attendees":[{"self":false,"responseStatus":"accepted"}]}]}"#,
            #"{"items":[{"iCalUID":"refinement@example.com","sequence":2,"attendees":[{"self":true,"responseStatus":"accepted"}]}]}"#,
            #"{"items":[{"iCalUID":"refinement@example.com","attendees":[{"self":true,"responseStatus":"unknown"}]}]}"#,
            #"{"items":[{"iCalUID":"refinement@example.com","attendees":[{"self":true,"responseStatus":"accepted"}]},{"iCalUID":"refinement@example.com","attendees":[{"self":true,"responseStatus":"declined"}]}]}"#
        ]
        for json in payloads {
            let api = GmailAPI(transport: CalendarStatusTransport([json])) { "token" }
            #expect(try await api.calendarStatus(for: CalendarFixtures.parse()) == nil)
        }
        let needsAction = GmailAPI(transport: CalendarStatusTransport([
            #"{"items":[{"iCalUID":"refinement@example.com","attendees":[{"self":true,"responseStatus":"needsAction"}]}]}"#
        ])) { "token" }
        #expect(try await needsAction.calendarStatus(for: CalendarFixtures.parse()) == .needsAction)
    }

    @Test("A disabled Calendar API is reported as a configuration problem rather than a generic sign-in failure")
    func disabledAPIDiagnostic() async throws {
        let json = #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"SERVICE_DISABLED","domain":"googleapis.com","metadata":{"service":"calendar-json.googleapis.com","consumer":"projects/123456"}}]}}"#
        let api = GmailAPI(transport: CalendarStatusTransport([json], status: 403), retryDelays: []) { "token" }
        do {
            _ = try await api.calendarStatus(for: CalendarFixtures.parse())
            Issue.record("A disabled Calendar API must fail")
        } catch {
            #expect(error is GoogleCalendarError)
            #expect(error.localizedDescription.contains("Calendar API is disabled"))
        }
    }

    @Test("Only expired authorization or insufficient scopes suggest reconnecting; API setup errors link to the right project")
    func errorRecoveryActions() async throws {
        let cases: [(Int, String, GoogleCalendarError, Bool)] = [
            (403, #"{"error":{"details":[{"reason":"SERVICE_DISABLED","metadata":{"consumer":"projects/123456"}}]}}"#, .apiDisabled(projectNumber: "123456"), false),
            (403, #"{"error":{"errors":[{"reason":"accessNotConfigured"}]}}"#, .apiDisabled(projectNumber: nil), false),
            (403, #"{"error":{"details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#, .permissionRequired, true),
            (403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#, .permissionRequired, true),
            (401, "{}", .authenticationRequired, true),
            (403, #"{"error":{"errors":[{"reason":"domainPolicy"}]}}"#, .http(403), false),
            (503, "{}", .http(503), false)
        ]
        for (code, json, expected, reconnect) in cases {
            let api = GmailAPI(transport: CalendarStatusTransport([json], status: code), retryDelays: []) { "token" }
            do {
                _ = try await api.calendarStatus(for: CalendarFixtures.parse())
                Issue.record("A rejected Calendar request must report its error")
            } catch {
                let calendarError = try #require(error as? GoogleCalendarError)
                #expect(calendarError == expected)
                #expect(calendarError.requiresReconnect == reconnect)
            }
        }
        let setup = try #require(GoogleCalendarError.apiDisabled(projectNumber: "123456").setupURL)
        #expect(setup.host == "console.cloud.google.com")
        #expect(setup.path == "/apis/library/calendar-json.googleapis.com")
        #expect(URLComponents(url: setup, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "project" }?.value == "123456")
        #expect(GoogleCalendarError.permissionRequired.setupURL == nil)
        #expect(GoogleCalendarError.apiDisabled(projectNumber: "123&redirect=evil").setupURL?.query == nil)
    }

    @Test("Denied reads and repeated pagination tokens are errors rather than guessed responses")
    func failedLookup() async throws {
        let denied = GmailAPI(transport: CalendarStatusTransport(["{}"], status: 403), retryDelays: []) { "token" }
        await #expect(throws: GoogleCalendarError.http(403)) { try await denied.calendarStatus(for: CalendarFixtures.parse()) }
        let looping = GmailAPI(transport: CalendarStatusTransport([#"{"nextPageToken":"same"}"#])) { "token" }
        await #expect(throws: GmailError.invalidResponse) { try await looping.calendarStatus(for: CalendarFixtures.parse()) }
    }
}

@Suite("Calendar response presentation", .timeLimit(.minutes(1)))
@MainActor
struct CalendarResponsePresentationTests {
    private var mail: GmailConversation {
        GmailConversation(id: "t", subject: "Invitation", messages: [CalendarFixtures.message("m")])
    }

    @Test("External replies override the stale invitation and earlier-session receipts, using the receiving account only")
    func externalReply() async throws {
        let a = HubAPI([mail])
        let b = HubAPI([])
        await a.setCalendarResult(.success(.declined))
        await b.setCalendarResult(.success(.accepted))
        let hub = await MailHubTests().makeHub(["a": a, "b": b], order: ["b", "a"], calendarAccess: ["a", "b"])
        let key = ConversationKey(accountID: "a", threadID: "t")
        let invitation = try CalendarFixtures.parse()
        try await hub.sendCalendarResponse(.tentative, to: invitation, key: key)
        let model = CalendarConversationModel(hub: hub, key: key)
        await model.load(mail)
        #expect(model.calendarStatus(for: invitation) == .declined)
        #expect(model.sentResponse(for: invitation) == nil)
        #expect(await a.calendarQueries == ["refinement@example.com"])
        #expect(await b.calendarQueries.isEmpty)
        #expect(model.canRespond(to: invitation, messageID: "m"))
        try await model.respond(.accepted, to: invitation, messageID: "m")
        #expect(model.sentResponse(for: invitation) == .accepted, "A just-sent reply is visible while Google catches up")
        let reopened = CalendarConversationModel(hub: hub, key: key)
        await reopened.load(mail)
        #expect(reopened.sentResponse(for: invitation) == nil)
        #expect(reopened.calendarStatus(for: invitation) == .declined)
        await a.setCalendarResult(.success(.tentative))
        await model.retry()
        #expect(model.sentResponse(for: invitation) == nil)
        #expect(model.calendarStatus(for: invitation) == .tentative)
    }

    @Test("Calendar failures preserve the invitation; only an explicit Calendar response can mean not responded")
    func unavailableStatus() async throws {
        let api = HubAPI([mail])
        await api.setCalendarResult(.failure(.http(403)))
        let hub = await MailHubTests().makeHub(["a": api], calendarAccess: ["a"])
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        let invitation = try CalendarFixtures.parse()
        await model.load(mail)
        #expect(model.invitations["m"]?.count == 1)
        #expect(model.errors.isEmpty)
        #expect(model.calendarStatus(for: invitation) == nil)
        #expect(model.calendarStatusMessage(for: invitation) != nil)
        #expect(model.canRespond(to: invitation, messageID: "m"))
        await api.setCalendarResult(.success(.needsAction))
        await model.retry()
        #expect(model.calendarStatus(for: invitation) == .needsAction)
        #expect(model.calendarStatusMessage(for: invitation) == nil)
        #expect(model.canRespond(to: invitation, messageID: "m"))
    }

    @Test("Calendar setup errors survive the complete API-to-card path instead of becoming generic reconnect advice")
    func setupErrorReachesCard() async throws {
        let json = #"{"error":{"code":403,"details":[{"reason":"SERVICE_DISABLED","metadata":{"consumer":"projects/123456"}}]}}"#
        let api = GmailAPI(transport: CalendarStatusTransport([json], status: 403), retryDelays: []) { "fixture-token" }
        let account = StoredAccount(
            identity: GoogleIdentity(id: "a", email: "a@example.com", name: nil),
            credentials: GoogleCredentials(refreshToken: "r", accessToken: "t", expiresAt: .distantFuture,
                                           scopes: Set(GoogleOAuthClient.requiredScopes + [GoogleOAuthClient.calendarEventsScope])),
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let accounts = AccountStore(vault: MemoryAccountVault([account]))
        accounts.restore()
        let hub = MailHub(accounts: accounts, persistsMail: false, syncsInBackground: false) { _ in api }
        await hub.reconcile()
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        await model.load(mail)
        let invitation = try CalendarFixtures.parse()
        let error = try #require(model.calendarStatusError(for: invitation))
        #expect(error == .apiDisabled(projectNumber: "123456"))
        #expect(!error.requiresReconnect)
        #expect(error.setupURL != nil)
        #expect(model.calendarStatusMessage(for: invitation)?.contains("Calendar API is disabled") == true)
        #expect(model.invitations["m"]?.count == 1)
    }

    @Test("An event not found in Calendar offers refresh, not an unnecessary reconnect")
    func missingEventIsNotAuthFailure() async throws {
        let api = HubAPI([mail])
        let hub = await MailHubTests().makeHub(["a": api], calendarAccess: ["a"])
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        await model.load(mail)
        let invitation = try CalendarFixtures.parse()
        #expect(model.calendarStatusMessage(for: invitation) != nil)
        #expect(model.calendarStatusError(for: invitation) == nil)
    }

    @Test("Without optional Calendar permission, invitation viewing and email RSVPs still work and no calendar is queried")
    func noCalendarPermission() async throws {
        let api = HubAPI([mail])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = CalendarConversationModel(hub: hub, key: ConversationKey(accountID: "a", threadID: "t"))
        await model.load(mail)
        let invitation = try CalendarFixtures.parse()
        #expect(model.invitations["m"]?.count == 1)
        #expect(model.canRespond(to: invitation, messageID: "m"))
        #expect(await api.calendarQueries.isEmpty)
        #expect(model.calendarStatus(for: invitation) == nil)
        #expect(!hub.accounts.accounts[0].needsReconnect)
    }
}
