import SwiftUI

extension EnvironmentValues {
    @Entry var calendarModel: CalendarConversationModel? = nil
}

struct CalendarInvitationList: View {
    let messageID: String
    @Environment(\.calendarModel) private var model

    var body: some View {
        if let model {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.errors[messageID] {
                    Label(error, systemImage: "calendar.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Try Again") { Task { await model.retry() } }
                        .disabled(model.isLoading)
                } else if let invitations = model.invitations[messageID] {
                    ForEach(invitations) { invitation in
                        CalendarInvitationCard(
                            invitation: invitation, sentResponse: model.sentResponse(for: invitation),
                            currentParticipation: model.hub.email(for: model.key.accountID).flatMap {
                                invitation.attendee(for: $0)?.participation
                            },
                            calendarStatus: model.calendarStatus(for: invitation),
                            responseStatusView: invitation.method == "REQUEST" ? CalendarResponseStatusView(
                                hasAccess: model.hasCalendarAccess, isChecking: model.isCheckingCalendar,
                                isConnecting: model.hub.accounts.isBusy,
                                message: model.hub.accounts.calendarConnectionErrors[model.key.accountID]
                                    ?? (model.hasCalendarAccess ? model.calendarStatusMessage(for: invitation) : nil),
                                connect: model.hub.email(for: model.key.accountID) == nil ? nil : {
                                    model.hub.accounts.enableCalendarAccess(model.key.accountID)
                                },
                                refresh: { Task { await model.retry() } },
                                canReconnect: model.calendarStatusError(for: invitation)?.requiresReconnect == true,
                                setupURL: model.calendarStatusError(for: invitation)?.setupURL
                            ) : nil,
                            isSuperseded: model.isSuperseded(invitation, messageID: messageID),
                            canRespond: model.canRespond(to: invitation, messageID: messageID),
                            accountEmail: model.hub.email(for: model.key.accountID),
                            respond: { try await model.respond($0, to: invitation, messageID: messageID) }
                        )
                    }
                } else if model.isLoading {
                    CalendarInvitationLoadingCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
