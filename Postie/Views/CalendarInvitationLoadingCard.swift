import SwiftUI

struct CalendarInvitationLoadingCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Loading invitation…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView().controlSize(.small)
        }
        .modifier(CalendarCardStyle())
    }
}

#if DEBUG
#Preview("Loading and loaded invitation") {
    VStack(spacing: 16) {
        CalendarInvitationLoadingCard()
        CalendarInvitationCard(invitation: CalendarPreviewData.invitation, canRespond: true,
                               accountEmail: "alex@example.com", respond: { _ in })
    }
    .padding(20)
    .frame(width: 680)
}

#Preview("Loading invitation · Compact dark") {
    CalendarInvitationLoadingCard()
        .padding(16)
        .frame(width: 380)
        .preferredColorScheme(.dark)
}
#endif
