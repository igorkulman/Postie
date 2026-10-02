import Foundation

// Lightweight checks for the demo model; no test target or project changes required.
@main
struct MailStoreChecks {
    @MainActor
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), "Failed: " + label)
            count += 1
            print("PASS: " + label)
        }

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let store = MailStore(threads: SampleMail.threads(now: now))
        let inbox = store.conversations(in: .inbox)
        expect(inbox.count == 6, "Inbox excludes sent mail")
        expect(store.conversations(in: .sent).count == 1, "Sent mailbox is separate")
        expect(inbox.first?.subject == "A little room to breathe", "Newest conversation comes first")
        expect(store.unreadCount == 3, "Unread badge counts inbox conversations")
        expect(store.conversations(in: .inbox, matching: "  COFFEE  ").count == 2, "Search ignores case and surrounding whitespace")
        expect(store.conversations(in: .inbox, matching: "james@example.com").count == 1, "Search includes sender addresses")
        expect(store.conversations(in: .inbox, matching: "scenic route").count == 1, "Search includes message bodies")
        expect(store.conversations(in: .inbox, matching: "missing phrase").isEmpty, "Unmatched search is empty")

        let unread = inbox.first { $0.isUnread }!
        store.markRead(unread.id)
        store.markRead(unread.id)
        expect(store.unreadCount == 2, "Marking read is idempotent")
        expect(store.conversations(in: .inbox, unreadOnly: true).count == 2, "Unread filter follows read state")
        store.toggleStar(unread.id)
        expect(store.threads.first { $0.id == unread.id }?.isStarred == true, "Star state changes")
        store.toggleStar(unread.id)
        expect(store.threads.first { $0.id == unread.id }?.isStarred == false, "Star state toggles back")

        let original = inbox[0]
        var reply = store.reply(to: original)
        expect(reply.recipient == "sophie@example.com", "Reply addresses the external sender")
        expect(reply.subject == "Re: A little room to breathe", "Reply prefixes the subject")
        expect(!reply.canSend, "Empty reply body cannot be sent")
        expect(store.sendDemo(reply) == nil, "Invalid send does not create mail")
        expect(store.conversations(in: .sent).count == 1, "Invalid send leaves Sent unchanged")

        store.saveDraft(ComposeDraft())
        expect(store.drafts.isEmpty, "Empty drafts are not saved")
        reply.body = "Coffee tomorrow sounds great."
        store.saveDraft(reply)
        reply.body = "Coffee tomorrow sounds great. See you at ten."
        store.saveDraft(reply)
        expect(store.drafts.count == 1, "Saving an existing draft updates rather than duplicates")
        expect(store.drafts[0].body == reply.body, "Draft edits are retained")
        expect(store.conversations(in: .drafts, matching: "ten").count == 1, "Drafts are searchable")

        let sentID = store.sendDemo(reply)
        expect(sentID != nil, "Valid demo send creates a sent conversation")
        expect(store.drafts.isEmpty, "Demo send removes its saved draft")
        expect(store.conversations(in: .sent).count == 2, "Demo send appears in Sent")
        let updated = store.threads.first { $0.id == original.id }!
        expect(updated.messages.count == 3, "Reply is appended to the original conversation")
        expect(store.reply(to: updated).recipient == "sophie@example.com", "Reply after own message still addresses external sender")

        let prefixed = MailThread(subject: "Re: Existing subject", messages: original.messages, mailbox: .inbox)
        expect(store.reply(to: prefixed).subject == prefixed.subject, "Reply does not duplicate Re prefix")

        for address in ["missing-at", "@example.com", "name@.com", "name@example.", "name@exa mple.com", "name@@example.com"] {
            let invalid = ComposeDraft(recipient: address, subject: "Hello", body: "Message")
            expect(!invalid.canSend, "Reject malformed recipient: " + address)
        }
        let saved = ComposeDraft(recipient: "friend@example.com", subject: "Later", body: "A draft")
        store.saveDraft(saved)
        store.deleteDraft(saved.id)
        expect(store.drafts.isEmpty, "Deleting a draft removes it")

        let actionStore = MailStore(threads: SampleMail.threads(now: now))
        let actionThread = actionStore.conversations(in: .inbox).first { $0.isUnread }!
        actionStore.archive(actionThread.id)
        expect(!actionStore.conversations(in: .inbox).contains { $0.id == actionThread.id }, "Archive removes the conversation from Inbox")
        expect(actionStore.conversations(in: .archive).first?.id == actionThread.id, "Archived mail is accessible in Archive")
        expect(actionStore.unreadCount == 2, "Archived unread mail no longer contributes to the Inbox badge")
        actionStore.moveToTrash(actionThread.id)
        expect(actionStore.conversations(in: .archive).isEmpty, "Delete removes the conversation from Archive")
        expect(actionStore.conversations(in: .trash).first?.messages == actionThread.messages, "Delete preserves messages in Trash")
        actionStore.moveToTrash(actionThread.id)
        expect(actionStore.conversations(in: .trash).count == 1, "Deleting again does not duplicate a conversation")
        actionStore.archive(actionThread.id)
        expect(actionStore.conversations(in: .trash).count == 1, "Archive does not move mail out of Trash")
        actionStore.archive(UUID())
        actionStore.moveToTrash(UUID())
        expect(actionStore.threads.count == 7, "Unknown action IDs leave the mailbox unchanged")

        let groupMessage = MailMessage(
            senderName: "Sophie Chen", senderEmail: "sophie@example.com",
            recipient: "alex@example.com, james@example.com",
            cc: "maya@example.com, SOPHIE@example.com, ALEX@example.com, james@example.com",
            date: now, body: "A group conversation."
        )
        let group = MailThread(subject: "Coffee plans", messages: [groupMessage], mailbox: .inbox)
        var replyAll = actionStore.reply(to: group, allRecipients: true)
        expect(replyAll.recipient == "sophie@example.com", "Reply All addresses the sender")
        expect(replyAll.cc == "james@example.com, maya@example.com", "Reply All excludes own address and case-insensitive duplicates")
        expect(actionStore.reply(to: group).cc.isEmpty, "Reply does not include other recipients")
        replyAll.body = "See you there."
        expect(replyAll.canSend, "Reply All accepts multiple valid CC addresses")
        actionStore.saveDraft(replyAll)
        expect(actionStore.conversations(in: .drafts, matching: "maya@example.com").count == 1, "Saved drafts are searchable by CC recipients")
        let replyAllID = actionStore.sendDemo(replyAll)!
        expect(actionStore.threads.first { $0.id == replyAllID }?.latestMessage?.cc == replyAll.cc, "Demo send retains CC recipients")
        replyAll.cc = "valid@example.com, invalid"
        expect(!replyAll.canSend, "Invalid CC address prevents sending")
        replyAll.cc = "valid@example.com,"
        expect(!replyAll.canSend, "Empty address in a CC list prevents sending")
        let multiple = ComposeDraft(recipient: "sophie@example.com, james@example.com", subject: "Hello", body: "Hi")
        expect(multiple.canSend, "Composer accepts multiple To recipients")

        let ownMessage = MailMessage(
            senderName: MailStore.accountName, senderEmail: MailStore.accountEmail,
            recipient: "sophie@example.com", date: now, body: "Hello Sophie"
        )
        let ownThread = MailThread(subject: "Hello", messages: [ownMessage], mailbox: .sent)
        expect(actionStore.reply(to: ownThread).recipient == "sophie@example.com", "Reply to sent mail addresses the recipient, not ourselves")

        let forwarded = actionStore.forward(group)
        expect(forwarded.recipient.isEmpty && forwarded.cc.isEmpty, "Forward starts without recipients")
        expect(!forwarded.canSend, "Forward cannot send without a recipient")
        expect(!ComposeDraft(subject: "Hello", body: "Hi").canSend, "New message cannot send without a recipient")
        expect(forwarded.subject == "Fwd: Coffee plans", "Forward prefixes the subject")
        expect(forwarded.body.contains(groupMessage.body) && forwarded.body.contains(groupMessage.senderEmail), "Forward includes the original body and sender")
        expect(forwarded.replyingTo == nil, "Forward does not append to the original thread")
        let alreadyForwarded = MailThread(subject: "Fwd: Coffee plans", messages: [groupMessage], mailbox: .inbox)
        expect(actionStore.forward(alreadyForwarded).subject == alreadyForwarded.subject, "Forward does not duplicate Fwd prefix")

        print("\(count) mailbox checks passed.")
    }
}
