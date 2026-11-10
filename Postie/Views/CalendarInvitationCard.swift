import SwiftUI

/// A compact, native summary above the original invitation email; no calendar access is needed.
struct CalendarInvitationCard: View {
    let invitation: CalendarInvitation
    var sentResponse: CalendarInvitation.Response?
    var currentParticipation: String?
    var calendarStatus: GoogleCalendarStatus?
    var responseStatusView: CalendarResponseStatusView?
    var isSuperseded = false
    var canRespond = false
    var accountEmail: String?
    var respond: ((CalendarInvitation.Response) async throws -> Void)?
    @State private var showsGuests = false
    @State private var isSending = false
    @State private var errorMessage: String?

    private var selectedResponse: CalendarInvitation.Response? {
        sentResponse ?? calendarStatus?.response ?? (calendarStatus == nil ? currentParticipation.flatMap(CalendarInvitation.Response.init(rawValue:)) : nil)
    }

    private var status: String {
        if invitation.isCancelled { return String(localized: "Cancelled event") }
        if isSuperseded { return String(localized: "A newer invitation is available") }
        if let sentResponse { return String(localized: "Reply sent: \(sentResponse.status)") }
        if let calendarStatus { return String(localized: "Your response: \(calendarStatus.title)") }
        if let currentParticipation, let response = CalendarInvitation.Response(rawValue: currentParticipation) {
            return String(localized: "Invitation says: \(response.status)")
        }
        if invitation.method == "REPLY" { return String(localized: "Calendar response") }
        if invitation.sequence > 0 { return String(localized: "Updated invitation") }
        return String(localized: "Calendar invitation")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(invitation.isCancelled ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(invitation.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(invitation.dateSummary)
                    if invitation.recurrenceID != nil {
                        Text("This occurrence only")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if invitation.isRecurring {
                        Label("Repeating event · reply applies to the series", systemImage: "repeat")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                if !invitation.location.isEmpty {
                    Label(invitation.location, systemImage: "mappin.and.ellipse")
                        .textSelection(.enabled)
                }
                if let url = invitation.meetingURL, !invitation.isCancelled {
                    Link(destination: url) {
                        Label("Open meeting link", systemImage: "video")
                    }
                    .help(url.absoluteString)
                }
                if let organizer = invitation.organizer {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Organizer").font(.caption).foregroundStyle(.secondary)
                        Text(organizer.name.isEmpty ? organizer.email : "\(organizer.name) <\(organizer.email)>")
                            .textSelection(.enabled)
                    }
                }
                if !invitation.attendees.isEmpty {
                    DisclosureGroup("Guests (\(invitation.attendees.count))", isExpanded: $showsGuests) {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(invitation.attendees.enumerated()), id: \.offset) { _, person in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: Self.symbol(for: participation(for: person)))
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel(Self.participationLabel(participation(for: person)))
                                    Text(person.name.isEmpty ? person.email : "\(person.name) <\(person.email)>")
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                if invitation.method == "REQUEST" && !invitation.isCancelled && !isSuperseded {
                    HStack(spacing: 8) {
                        ForEach(CalendarInvitation.Response.allCases, id: \.self) { response in
                            CalendarResponseButton(response: response, isSelected: selectedResponse == response,
                                                   isDisabled: !canRespond || isSending) { send(response) }
                        }
                        if isSending { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.small)
                    if let accountEmail, invitation.canRespond(as: accountEmail) {
                        Text("Replies are sent to the organizer from \(accountEmail).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("RSVP is unavailable for this invitation from this account. Use the original email for more options.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let responseStatusView { responseStatusView }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CalendarCardStyle())
    }

    private func send(_ response: CalendarInvitation.Response) {
        guard !isSending, canRespond, selectedResponse != response, let respond else { return }
        isSending = true
        errorMessage = nil
        // A user-initiated send finishes even if the user navigates to another conversation.
        Task { @MainActor in
            defer { isSending = false }
            do { try await respond(response) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func participation(for person: CalendarInvitation.Person) -> String {
        guard let accountEmail, person.email.caseInsensitiveCompare(accountEmail) == .orderedSame else { return person.participation }
        if let selectedResponse { return selectedResponse.rawValue }
        return calendarStatus == .needsAction ? "NEEDS-ACTION" : person.participation
    }

    private static func symbol(for participation: String) -> String {
        switch participation {
        case "ACCEPTED": "checkmark.circle"
        case "DECLINED": "xmark.circle"
        case "TENTATIVE": "questionmark.circle"
        default: "circle.dotted"
        }
    }

    private static func participationLabel(_ participation: String) -> String {
        CalendarInvitation.Response(rawValue: participation)?.status ?? String(localized: "Awaiting response")
    }
}

#if DEBUG
#Preview("Invitation") {
    CalendarInvitationCard(invitation: CalendarPreviewData.invitation, canRespond: true,
                           accountEmail: "alex@example.com", respond: { _ in })
        .padding(20)
        .frame(width: 680)
}

#Preview("Invitation · Compact dark") {
    CalendarInvitationCard(invitation: CalendarPreviewData.invitation, sentResponse: .tentative, canRespond: true,
                           accountEmail: "alex@example.com", respond: { _ in })
        .padding(16)
        .frame(width: 380)
        .preferredColorScheme(.dark)
}

#Preview("Calendar response · Accepted") {
    CalendarInvitationCard(
        invitation: CalendarPreviewData.invitation, calendarStatus: .accepted,
        responseStatusView: CalendarResponseStatusView(hasAccess: true, isChecking: false, isConnecting: false,
                                                     message: nil, connect: nil, refresh: {}),
        canRespond: true, accountEmail: "alex@example.com", respond: { _ in }
    )
    .padding(16)
    .frame(width: 380)
    .preferredColorScheme(.dark)
}

#Preview("Connect Calendar") {
    CalendarInvitationCard(
        invitation: CalendarPreviewData.invitation,
        responseStatusView: CalendarResponseStatusView(hasAccess: false, isChecking: false, isConnecting: false,
                                                     message: nil, connect: {}, refresh: nil),
        canRespond: true, accountEmail: "alex@example.com", respond: { _ in }
    )
    .padding(20)
    .frame(width: 680)
}

#Preview("Cancelled invitation") {
    CalendarInvitationCard(invitation: CalendarPreviewData.cancelled)
        .padding(20)
        .frame(width: 580)
}
#endif
