import SwiftUI

struct CalendarResponseStatusView: View {
    let hasAccess: Bool
    let isChecking: Bool
    let isConnecting: Bool
    let message: String?
    let connect: (() -> Void)?
    let refresh: (() -> Void)?
    var canReconnect = false
    var setupURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setupURL {
                Link("Enable Google Calendar API…", destination: setupURL)
            }
            if hasAccess {
                HStack(spacing: 8) {
                    if isChecking { ProgressView().controlSize(.mini) }
                    Text(isChecking ? String(localized: "Checking your Calendar response…")
                         : (message == nil ? String(localized: "Response from Google Calendar") : String(localized: "Calendar response unavailable")))
                        .foregroundStyle(.secondary)
                    if let refresh {
                        Button("Refresh response", systemImage: "arrow.clockwise", action: refresh)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(isChecking)
                    }
                }
                if canReconnect, let connect {
                    Button("Reconnect Google Calendar…", action: connect)
                        .disabled(isConnecting || isChecking)
                        .controlSize(.small)
                }
            } else if let connect {
                Text("Connect Calendar to see replies made in Gmail or other calendar apps.")
                    .foregroundStyle(.secondary)
                Button("Connect Google Calendar…", action: connect)
                    .disabled(isConnecting)
                    .controlSize(.small)
            }
        }
        .font(.caption)
    }
}

#if DEBUG
#Preview("Calendar API setup error") {
    let error = GoogleCalendarError.apiDisabled(projectNumber: "123456")
    CalendarInvitationCard(
        invitation: CalendarPreviewData.invitation,
        responseStatusView: CalendarResponseStatusView(
            hasAccess: true, isChecking: false, isConnecting: false, message: error.localizedDescription,
            connect: {}, refresh: {}, canReconnect: error.requiresReconnect, setupURL: error.setupURL
        ),
        canRespond: true, accountEmail: "alex@example.com", respond: { _ in }
    )
    .padding(20)
    .frame(width: 680)
}

#Preview("Calendar authorization expired · Compact dark") {
    let error = GoogleCalendarError.authenticationRequired
    CalendarInvitationCard(
        invitation: CalendarPreviewData.invitation,
        responseStatusView: CalendarResponseStatusView(
            hasAccess: true, isChecking: false, isConnecting: false, message: error.localizedDescription,
            connect: {}, refresh: {}, canReconnect: error.requiresReconnect
        ),
        canRespond: true, accountEmail: "alex@example.com", respond: { _ in }
    )
    .padding(16)
    .frame(width: 380)
    .preferredColorScheme(.dark)
}
#endif
