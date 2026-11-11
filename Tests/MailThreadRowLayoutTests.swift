import AppKit
import SwiftUI
import Testing
@testable import Postie

@Suite("Conversation row layout")
@MainActor
struct MailThreadRowLayoutTests {
    @Test("A long notification keeps its subject and preview under a one-line height proposal")
    func notificationResistsVerticalCompression() throws {
        for width in [280.0, 330.0, 440.0] {
            let thread = MailThread(
                id: "notification", subject: "tw-ios | Failed pipeline for fix/link-previews | 152f7722",
                messages: [MailMessage(id: "notification-message", senderName: "GitLab", senderEmail: "gitlab@example.com",
                                       recipient: "alex@example.com", date: Date(timeIntervalSince1970: 1_794_396_360),
                                       body: "Pipeline #95082 has failed! Project teamwire / tw-ios. Branch fix/link-previews. Commit 152f7722.")],
                mailbox: .inbox
            )
            let renderer = ImageRenderer(content: MailThreadRow(thread: thread))
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            let natural = try #require(renderer.nsImage)
            // A compact table measurement must not squeeze away the row's subject or preview.
            renderer.proposedSize = ProposedViewSize(width: width, height: 24)
            let image = try #require(renderer.nsImage)
            #expect(image.size.height == natural.size.height)
            #expect(image.size.width <= width)
        }
    }
}
