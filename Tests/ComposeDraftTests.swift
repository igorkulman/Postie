import Foundation
import Testing
@testable import Postie

@Suite("Replies and forwards")
@MainActor
struct ComposeDraftTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let me = SampleAccount.email

    private func groupThread(subject: String = "Coffee plans") -> MailThread {
        let message = MailMessage(id: "sophie", senderName: "Sophie Chen", senderEmail: "sophie@example.com",
                                  recipient: "alex@example.com, james@example.com",
                                  cc: "maya@example.com, SOPHIE@example.com, ALEX@example.com, james@example.com",
                                  date: now, body: "A group conversation.")
        return MailThread(id: "coffee-plans", subject: subject, messages: [message], mailbox: .inbox)
    }

    @Test("A reply addresses the sender and cannot be sent until something is written")
    func reply() {
        let reply = ComposeDraft.reply(to: groupThread(), accountEmail: me)
        #expect(reply.recipient == "sophie@example.com")
        #expect(reply.subject == "Re: Coffee plans")
        #expect(reply.cc.isEmpty)
        #expect(!reply.canSend)
    }

    @Test("Reply subjects do not duplicate Re prefixes")
    func replyPrefix() {
        #expect(ComposeDraft.reply(to: groupThread(subject: "Re: Existing"), accountEmail: me).subject == "Re: Existing")
    }

    @Test("Reply All deduplicates recipients and keeps Cc")
    func replyAll() {
        var reply = ComposeDraft.reply(to: groupThread(), accountEmail: me, allRecipients: true)
        #expect(reply.recipient == "sophie@example.com")
        #expect(reply.cc == "james@example.com, maya@example.com")
        reply.ownText = "See you there."
        #expect(reply.canSend)
    }

    @Test("Replying to sent mail addresses the recipient rather than ourselves")
    func replyToOwnMessage() {
        let own = MailMessage(id: "own", senderName: SampleAccount.name, senderEmail: me,
                              recipient: "sophie@example.com", date: now, body: "Hello Sophie")
        let thread = MailThread(id: "hello", subject: "Hello", messages: [own], mailbox: .sent)
        #expect(ComposeDraft.reply(to: thread, accountEmail: me).recipient == "sophie@example.com")
    }

    @Test("A forward quotes the original and starts a new conversation")
    func forward() throws {
        let group = groupThread()
        let original = try #require(group.latestMessage)
        let forwarded = ComposeDraft.forward(group)
        #expect(forwarded.recipient.isEmpty && forwarded.cc.isEmpty)
        #expect(!forwarded.canSend)
        #expect(forwarded.subject == "Fwd: Coffee plans")
        #expect(forwarded.body.contains(original.body))
        #expect(forwarded.body.contains(original.senderEmail))
        #expect(forwarded.replyingTo == nil)
        #expect(ComposeDraft.forward(groupThread(subject: "Fwd: Coffee plans")).subject == "Fwd: Coffee plans")
    }

    @Test("Malformed To addresses prevent sending", arguments: [
        "missing-at", "@example.com", "name@.com", "name@example.", "name@exa mple.com", "name@@example.com"
    ])
    func malformedRecipient(address: String) {
        #expect(!ComposeDraft(recipient: address, subject: "Hello", body: "Message").canSend)
    }

    @Test("Malformed Cc lists prevent sending", arguments: ["valid@example.com, invalid", "valid@example.com,"])
    func malformedCC(cc: String) {
        #expect(!ComposeDraft(recipient: "sophie@example.com", cc: cc, subject: "Hello", body: "Hi").canSend)
    }

    @Test("Several recipients are fine, none is not")
    func recipients() {
        #expect(ComposeDraft(recipient: "sophie@example.com, james@example.com", subject: "Hello", body: "Hi").canSend)
        #expect(!ComposeDraft(subject: "Hello", body: "Hi").canSend)
    }
}
