import Foundation
import Testing
@testable import iMail

@Suite("Demo mailbox")
@MainActor
struct MailStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeStore() -> MailStore {
        MailStore(threads: SampleMail.threads(now: now))
    }

    @Test("Mailboxes are separate and newest conversations come first")
    func mailboxFiltering() {
        let store = makeStore()
        #expect(store.conversations(in: .inbox).count == 6)
        #expect(store.conversations(in: .sent).count == 1)
        #expect(store.conversations(in: .inbox).first?.subject == "A little room to breathe")
        #expect(store.unreadCount == 3)
    }

    @Test("Search matches headers and bodies, ignoring case and surrounding whitespace")
    func search() {
        let store = makeStore()
        #expect(store.conversations(in: .inbox, matching: "  COFFEE  ").count == 2)
        #expect(store.conversations(in: .inbox, matching: "james@example.com").count == 1)
        #expect(store.conversations(in: .inbox, matching: "scenic route").count == 1)
        #expect(store.conversations(in: .inbox, matching: "missing phrase").isEmpty)
    }

    @Test("Marking read is idempotent and updates the unread filter")
    func readState() throws {
        let store = makeStore()
        let unread = try #require(store.conversations(in: .inbox).first { $0.isUnread })
        store.markRead(unread.id)
        store.markRead(unread.id)
        #expect(store.unreadCount == 2)
        #expect(store.conversations(in: .inbox, unreadOnly: true).count == 2)
    }

    @Test("Stars toggle in both directions")
    func stars() throws {
        let store = makeStore()
        let thread = try #require(store.conversations(in: .inbox).first { !$0.isStarred })
        store.toggleStar(thread.id)
        #expect(store.threads.first { $0.id == thread.id }?.isStarred == true)
        store.toggleStar(thread.id)
        #expect(store.threads.first { $0.id == thread.id }?.isStarred == false)
    }

    @Test("Reply addresses the sender and invalid sends leave Sent unchanged")
    func replyAndInvalidSend() throws {
        let store = makeStore()
        let original = try #require(store.conversations(in: .inbox).first)
        let reply = store.reply(to: original)
        #expect(reply.recipient == "sophie@example.com")
        #expect(reply.subject == "Re: A little room to breathe")
        #expect(!reply.canSend)
        #expect(store.sendDemo(reply) == nil)
        #expect(store.conversations(in: .sent).count == 1)
    }

    @Test("Saving drafts updates existing entries and makes them searchable")
    func draftUpdates() {
        let store = makeStore()
        store.saveDraft(ComposeDraft())
        #expect(store.drafts.isEmpty)
        var draft = ComposeDraft(recipient: "friend@example.com", subject: "Coffee", body: "See you.")
        store.saveDraft(draft)
        draft.body = "See you at ten."
        store.saveDraft(draft)
        #expect(store.drafts.count == 1)
        #expect(store.drafts.first?.body == draft.body)
        #expect(store.conversations(in: .drafts, matching: "ten").count == 1)
    }

    @Test("Demo sending removes the draft and appends a reply to its conversation")
    func simulatedSend() throws {
        let store = makeStore()
        let original = try #require(store.conversations(in: .inbox).first)
        var reply = store.reply(to: original)
        reply.body = "Coffee tomorrow sounds great."
        store.saveDraft(reply)
        let sentID = try #require(store.sendDemo(reply))
        #expect(store.drafts.isEmpty)
        #expect(store.conversations(in: .sent).count == 2)
        #expect(store.conversations(in: .sent).contains { $0.id == sentID })
        let updated = try #require(store.threads.first { $0.id == original.id })
        #expect(updated.messages.count == 3)
        #expect(store.reply(to: updated).recipient == "sophie@example.com")
    }

    @Test("Reply subjects do not duplicate Re prefixes")
    func replyPrefix() throws {
        let store = makeStore()
        let original = try #require(store.conversations(in: .inbox).first)
        let thread = MailThread(subject: "Re: Existing subject", messages: original.messages, mailbox: .inbox)
        #expect(store.reply(to: thread).subject == thread.subject)
    }

    @Test("Malformed To addresses prevent sending", arguments: [
        "missing-at", "@example.com", "name@.com", "name@example.", "name@exa mple.com", "name@@example.com"
    ])
    func malformedRecipient(address: String) {
        #expect(!ComposeDraft(recipient: address, subject: "Hello", body: "Message").canSend)
    }

    @Test("Deleting a draft removes it")
    func draftDeletion() {
        let store = makeStore()
        let draft = ComposeDraft(recipient: "friend@example.com", subject: "Later", body: "A draft")
        store.saveDraft(draft)
        store.deleteDraft(draft.id)
        #expect(store.drafts.isEmpty)
    }

    @Test("Archive and Trash preserve messages and update the Inbox badge")
    func archiveAndTrash() throws {
        let store = makeStore()
        let thread = try #require(store.conversations(in: .inbox).first { $0.isUnread })
        store.archive(thread.id)
        #expect(!store.conversations(in: .inbox).contains { $0.id == thread.id })
        #expect(store.conversations(in: .archive).first?.id == thread.id)
        #expect(store.unreadCount == 2)
        store.moveToTrash(thread.id)
        #expect(store.conversations(in: .archive).isEmpty)
        #expect(store.conversations(in: .trash).first?.messages == thread.messages)
        store.moveToTrash(thread.id)
        #expect(store.conversations(in: .trash).count == 1)
        store.archive(thread.id)
        #expect(store.conversations(in: .trash).count == 1)
    }

    @Test("Actions with unknown IDs leave the mailbox unchanged")
    func unknownActionIDs() {
        let store = makeStore()
        store.archive(UUID())
        store.moveToTrash(UUID())
        #expect(store.threads.count == 7)
    }

    @Test("Reply All deduplicates recipients and retains Cc through drafts and sending")
    func replyAll() throws {
        let store = makeStore()
        let group = groupThread()
        var reply = store.reply(to: group, allRecipients: true)
        #expect(reply.recipient == "sophie@example.com")
        #expect(reply.cc == "james@example.com, maya@example.com")
        #expect(store.reply(to: group).cc.isEmpty)
        reply.body = "See you there."
        #expect(reply.canSend)
        store.saveDraft(reply)
        #expect(store.conversations(in: .drafts, matching: "maya@example.com").count == 1)
        let sentID = try #require(store.sendDemo(reply))
        #expect(store.threads.first { $0.id == sentID }?.latestMessage?.cc == reply.cc)
    }

    @Test("Malformed Cc lists prevent sending", arguments: ["valid@example.com, invalid", "valid@example.com,"])
    func malformedCC(cc: String) {
        let draft = ComposeDraft(recipient: "sophie@example.com", cc: cc, subject: "Hello", body: "Hi")
        #expect(!draft.canSend)
    }

    @Test("Multiple To addresses are supported but an empty recipient is not")
    func multipleRecipients() {
        #expect(ComposeDraft(recipient: "sophie@example.com, james@example.com", subject: "Hello", body: "Hi").canSend)
        #expect(!ComposeDraft(subject: "Hello", body: "Hi").canSend)
    }

    @Test("Reply to sent mail addresses the recipient rather than ourselves")
    func replyToOwnMessage() {
        let store = makeStore()
        let ownMessage = MailMessage(senderName: MailStore.accountName, senderEmail: MailStore.accountEmail,
                                     recipient: "sophie@example.com", date: now, body: "Hello Sophie")
        let thread = MailThread(subject: "Hello", messages: [ownMessage], mailbox: .sent)
        #expect(store.reply(to: thread).recipient == "sophie@example.com")
    }

    @Test("Forward quotes the original message without appending to its conversation")
    func forwarding() throws {
        let store = makeStore()
        let group = groupThread()
        let original = try #require(group.latestMessage)
        let forwarded = store.forward(group)
        #expect(forwarded.recipient.isEmpty && forwarded.cc.isEmpty)
        #expect(!forwarded.canSend)
        #expect(forwarded.subject == "Fwd: Coffee plans")
        #expect(forwarded.body.contains(original.body))
        #expect(forwarded.body.contains(original.senderEmail))
        #expect(forwarded.replyingTo == nil)
        let prefixed = MailThread(subject: "Fwd: Coffee plans", messages: group.messages, mailbox: .inbox)
        #expect(store.forward(prefixed).subject == prefixed.subject)
    }

    private func groupThread() -> MailThread {
        let message = MailMessage(senderName: "Sophie Chen", senderEmail: "sophie@example.com",
                                  recipient: "alex@example.com, james@example.com",
                                  cc: "maya@example.com, SOPHIE@example.com, ALEX@example.com, james@example.com",
                                  date: now, body: "A group conversation.")
        return MailThread(subject: "Coffee plans", messages: [message], mailbox: .inbox)
    }
}
