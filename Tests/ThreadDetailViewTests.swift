import Foundation
import SwiftUI
import Testing
@testable import Postie

@Suite("Conversation opening position")
@MainActor
struct ThreadDetailViewTests {
    private func message(_ number: Int) -> MailMessage {
        MailMessage(senderName: "Sender \(number)", senderEmail: "sender@example.com",
                    recipient: "alex@example.com", date: Date(timeIntervalSince1970: Double(number)),
                    body: "Message \(number)")
    }

    @Test("A conversation opens at its latest message, not at the bottom edge")
    func latestHeader() throws {
        let thread = MailThread(subject: "Conversation", messages: (1...25).map(message), mailbox: .inbox)
        let latest = try #require(thread.latestMessage)
        let position = ThreadDetailView.openingScrollPosition(for: thread)
        #expect(position.viewID(type: UUID.self) == latest.id)
        #expect(position.edge == nil)
        #expect(!position.isPositionedByUser)
    }

    @Test("A single message opens at the top so its subject remains visible")
    func singleMessage() {
        let thread = MailThread(subject: "Single email", messages: [message(1)], mailbox: .inbox)
        let position = ThreadDetailView.openingScrollPosition(for: thread)
        #expect(position.edge == .top)
        #expect(position.viewID(type: UUID.self) == nil)
    }

    @Test("An empty conversation has no invalid message scroll target")
    func emptyConversation() {
        let thread = MailThread(subject: "Empty", messages: [], mailbox: .inbox)
        let position = ThreadDetailView.openingScrollPosition(for: thread)
        #expect(position.edge == .top)
        #expect(position.viewID(type: UUID.self) == nil)
    }

    @Test("Opening another conversation chooses that conversation's message")
    func switchingConversations() {
        let first = MailThread(subject: "First", messages: [message(1), message(2)], mailbox: .inbox)
        let second = MailThread(subject: "Second", messages: [message(3), message(4)], mailbox: .sent)
        let firstID = ThreadDetailView.openingScrollPosition(for: first).viewID(type: UUID.self)
        let secondID = ThreadDetailView.openingScrollPosition(for: second).viewID(type: UUID.self)
        #expect(firstID != secondID)
        #expect(secondID == second.latestMessage?.id)
    }

    @Test("HTML conversations use the same header target, independent of body length")
    func htmlConversation() {
        var latest = message(2)
        latest.htmlBody = "<div style='height:5000px'>Latest message</div>"
        let thread = MailThread(subject: "HTML conversation", messages: [message(1), latest], mailbox: .inbox)
        #expect(ThreadDetailView.openingScrollPosition(for: thread).viewID(type: UUID.self) == latest.id)
    }
}
