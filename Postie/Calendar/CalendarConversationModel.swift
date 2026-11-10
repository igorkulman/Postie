import Foundation
import Observation

/// One owner for loaded invitations in a conversation, so older cards know about updates and cancellations.
@MainActor
@Observable
final class CalendarConversationModel {
    struct LoadRequest: Equatable {
        let conversation: GmailConversation
        let calendarAccess: Bool
        let authorizationID: UUID?
    }

    let hub: MailHub
    let key: ConversationKey
    private(set) var invitations: [String: [CalendarInvitation]] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var isLoading = true
    private var messageOrder: [String] = []
    private var loadedSources: [String: [CalendarSource]] = [:]
    private var generation = Generation()
    private var conversation: GmailConversation?
    private(set) var calendarStatuses: [CalendarResponseKey: GoogleCalendarStatus] = [:]
    private(set) var calendarStatusErrors: [CalendarResponseKey: GoogleCalendarError] = [:]
    private(set) var isCheckingCalendar = false
    private var checkedCalendarStatuses: Set<CalendarResponseKey> = []
    private var locallyReplied: Set<CalendarResponseKey> = []

    var hasCalendarAccess: Bool { hub.accounts.hasCalendarAccess(key.accountID) }

    func loadRequest(for conversation: GmailConversation) -> LoadRequest {
        LoadRequest(conversation: conversation, calendarAccess: hasCalendarAccess,
                    authorizationID: hub.accounts.accounts.first { $0.id == key.accountID }?.authorizationID)
    }

    init(hub: MailHub, key: ConversationKey) {
        self.hub = hub
        self.key = key
    }

    func load(_ conversation: GmailConversation) async {
        generation.advance()
        let started = generation
        self.conversation = conversation
        isLoading = true
        defer {
            if generation == started { isLoading = false; isCheckingCalendar = false }
        }
        messageOrder = conversation.messages.map(\.id)
        let ids = Set(conversation.messages.filter { !$0.calendarSources.isEmpty }.map(\.id))
        invitations = invitations.filter { ids.contains($0.key) }
        errors = errors.filter { ids.contains($0.key) }
        loadedSources = loadedSources.filter { ids.contains($0.key) }
        for message in conversation.messages where !message.calendarSources.isEmpty {
            if loadedSources[message.id] == message.calendarSources { continue }
            do {
                var events: [CalendarInvitation] = []
                for source in message.calendarSources {
                    try Task.checkCancellation()
                    guard generation == started else { return }
                    let data = try await hub.calendarData(source, messageID: message.id, key: key)
                    let parsed = try await Self.parse(data, method: source.method)
                    for event in parsed where !events.contains(where: { $0.id == event.id }) { events.append(event) }
                }
                try Task.checkCancellation()
                guard generation == started else { return }
                invitations[message.id] = events
                loadedSources[message.id] = message.calendarSources
                errors[message.id] = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == started else { return }
                invitations[message.id] = nil
                errors[message.id] = error.localizedDescription
            }
        }
        guard generation == started, !Task.isCancelled else { return }
        isLoading = false
        guard hasCalendarAccess else {
            calendarStatuses = [:]
            calendarStatusErrors = [:]
            checkedCalendarStatuses = []
            return
        }
        isCheckingCalendar = true
        var seen: Set<CalendarResponseKey> = []
        for id in messageOrder {
            for invitation in invitations[id] ?? [] where invitation.method == "REQUEST" {
                let receipt = CalendarResponseKey(accountID: key.accountID, invitation: invitation)
                guard seen.insert(receipt).inserted else { continue }
                do {
                    let status = try await hub.calendarStatus(for: invitation, accountID: key.accountID)
                    try Task.checkCancellation()
                    guard generation == started else { return }
                    calendarStatuses[receipt] = status
                    checkedCalendarStatuses.insert(receipt)
                    calendarStatusErrors[receipt] = nil
                } catch is CancellationError { return }
                catch {
                    guard generation == started, !Task.isCancelled else { return }
                    calendarStatuses[receipt] = nil
                    calendarStatusErrors[receipt] = GoogleCalendarError.fromLookup(error)
                }
            }
        }
    }

    func retry() async {
        guard let conversation else { return }
        locallyReplied = []
        await load(conversation)
    }

    @concurrent
    private static func parse(_ data: Data, method: String?) async throws -> [CalendarInvitation] {
        try ICalendarParser.invitations(from: data, method: method)
    }

    func isSuperseded(_ invitation: CalendarInvitation, messageID: String) -> Bool {
        guard let index = messageOrder.firstIndex(of: messageID) else { return true }
        for (offset, id) in messageOrder.enumerated() {
            if (invitations[id] ?? []).contains(where: { other in
                guard other.uid == invitation.uid,
                      other.organizer?.email.lowercased() == invitation.organizer?.email.lowercased(),
                      other.method == "REQUEST" || other.method == "CANCEL" else { return false }
                // A whole-series cancellation also supersedes an occurrence invitation.
                guard other.eventKey == invitation.eventKey || (other.isCancelled && other.recurrenceID == nil) else { return false }
                return other.sequence > invitation.sequence || (other.sequence == invitation.sequence && offset > index)
            }) { return true }
        }
        return false
    }

    func canRespond(to invitation: CalendarInvitation, messageID: String) -> Bool {
        guard !isLoading, !isCheckingCalendar, errors.isEmpty,
              invitations[messageID]?.contains(invitation) == true, let email = hub.email(for: key.accountID),
              hub.sendingAccounts.contains(where: { $0.id == key.accountID }) else { return false }
        return invitation.canRespond(as: email) && !isSuperseded(invitation, messageID: messageID)
            && !hub.calendarRepliesInFlight.contains(CalendarResponseKey(accountID: key.accountID, invitation: invitation))
    }

    func calendarStatus(for invitation: CalendarInvitation) -> GoogleCalendarStatus? {
        guard hasCalendarAccess else { return nil }
        return calendarStatuses[CalendarResponseKey(accountID: key.accountID, invitation: invitation)]
    }

    func calendarStatusError(for invitation: CalendarInvitation) -> GoogleCalendarError? {
        calendarStatusErrors[CalendarResponseKey(accountID: key.accountID, invitation: invitation)]
    }

    func calendarStatusMessage(for invitation: CalendarInvitation) -> String? {
        let receipt = CalendarResponseKey(accountID: key.accountID, invitation: invitation)
        if let error = calendarStatusErrors[receipt] { return error.localizedDescription }
        if checkedCalendarStatuses.contains(receipt), calendarStatuses[receipt] == nil {
            return String(localized: "No response found in your primary Google Calendar.")
        }
        return nil
    }

    func sentResponse(for invitation: CalendarInvitation) -> CalendarInvitation.Response? {
        let receipt = CalendarResponseKey(accountID: key.accountID, invitation: invitation)
        // A fresh Calendar snapshot wins over receipts from an earlier visit. A reply just
        // sent from this card stays visible while Google's calendar processing catches up.
        if calendarStatus(for: invitation) != nil, !locallyReplied.contains(receipt) { return nil }
        return hub.calendarResponses[receipt]
    }

    func respond(_ response: CalendarInvitation.Response, to invitation: CalendarInvitation, messageID: String) async throws {
        guard canRespond(to: invitation, messageID: messageID) else { throw CalendarInvitationError.cannotRespond }
        try await hub.sendCalendarResponse(response, to: invitation, key: key)
        locallyReplied.insert(CalendarResponseKey(accountID: key.accountID, invitation: invitation))
    }
}
