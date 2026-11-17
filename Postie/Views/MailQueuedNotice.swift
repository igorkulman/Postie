import SwiftUI

struct MailQueuedNotice: View {
    let showOutbox: () -> Void
    let dismiss: () -> Void

    var body: some View {
        MailStatusCard(message: String(localized: "Message queued for sending"), timeout: .seconds(6), dismiss: dismiss) {
            Image(systemName: "paperplane.fill").foregroundStyle(.secondary)
        } actions: {
            Button("Show Outbox", action: showOutbox)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
    }
}
