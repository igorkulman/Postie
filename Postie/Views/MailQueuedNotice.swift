import SwiftUI

struct MailQueuedNotice: View {
    let showOutbox: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Message queued for sending", systemImage: "paperplane")
            Spacer(minLength: 8)
            Button("Show Outbox", action: showOutbox)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            dismiss()
        }
    }
}
