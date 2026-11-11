#if DEBUG
import SwiftUI

private let notificationPreview = MailThread(
    id: "pipeline-notification",
    subject: "tw-ios | Failed pipeline for fix/link-previews | 152f7722",
    messages: [MailMessage(id: "pipeline-message", senderName: "GitLab", senderEmail: "gitlab@example.com",
                           recipient: SampleAccount.email, date: Date(timeIntervalSince1970: 1_794_396_360),
                           body: "Pipeline #95082 has failed! Project teamwire / tw-ios. Branch fix/link-previews. Commit 152f7722.")],
    mailbox: .inbox
)

private struct IncomingNotificationPreview: View {
    var selectNotification = false
    @State private var threads = Array(SampleMail.threads().prefix(2))
    @State private var selection: String? = SampleMail.threads().first?.id

    var body: some View {
        ScrollViewReader { _ in
            List(selection: $selection) {
                ForEach(threads) { thread in
                    MailThreadRow(thread: thread)
                        .tag(thread.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
        }
        .animation(.easeInOut(duration: 0.22), value: threads.map(\.id))
        .task {
            threads.insert(notificationPreview, at: 0)
            if selectNotification { selection = notificationPreview.id }
        }
    }
}

#Preview("Incoming GitLab notification") {
    IncomingNotificationPreview()
        .frame(width: 330, height: 500)
}

#Preview("Selected GitLab notification · Narrow dark") {
    IncomingNotificationPreview(selectNotification: true)
        .frame(width: 280, height: 500)
        .preferredColorScheme(.dark)
}

#Preview("Long notification row") {
    MailThreadRow(thread: notificationPreview)
        .padding(.horizontal, 16)
        .frame(width: 330)
}
#endif
