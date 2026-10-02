import Foundation
import Observation

/// The in-memory sample mailbox behind demo mode.
@MainActor
@Observable
final class MailStore {
    static let accountName = "Alex Morgan"
    static let accountEmail = "alex@example.com"

    private(set) var threads: [MailThread]
    private(set) var drafts: [ComposeDraft] = []

    init(threads: [MailThread] = SampleMail.threads()) {
        self.threads = threads
    }

    func conversations(in mailbox: Mailbox, matching query: String = "", unreadOnly: Bool = false) -> [MailThread] {
        let source: [MailThread]
        if mailbox == .drafts {
            source = drafts.map { draft in
                MailThread(
                    id: draft.id,
                    subject: draft.subject.isEmpty ? String(localized: "Untitled draft") : draft.subject,
                    messages: [MailMessage(
                        id: draft.id + "-message",
                        senderName: draft.recipient.isEmpty ? String(localized: "No recipient") : draft.recipient,
                        senderEmail: Self.accountEmail,
                        recipient: draft.recipient,
                        cc: draft.cc,
                        date: draft.updatedAt,
                        body: draft.body
                    )],
                    mailbox: .drafts
                )
            }
        } else {
            source = threads.filter { $0.mailbox == mailbox }
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.filter { thread in
            (!unreadOnly || thread.isUnread) && (
                term.isEmpty
                || thread.subject.localizedCaseInsensitiveContains(term)
                || thread.messages.contains {
                    [$0.senderName, $0.senderEmail, $0.recipient, $0.cc, $0.body].contains {
                        $0.localizedCaseInsensitiveContains(term)
                    }
                }
            )
        }.sorted { ($0.latestMessage?.date ?? .distantPast) > ($1.latestMessage?.date ?? .distantPast) }
    }

    var unreadCount: Int {
        threads.filter { $0.mailbox == .inbox && $0.isUnread }.count
    }

    func markRead(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isUnread = false
    }

    func markUnread(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isUnread = true
    }

    func toggleStar(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].isStarred.toggle()
    }

    func archive(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id && $0.mailbox == .inbox }) else { return }
        threads[index].mailbox = .archive
    }

    func moveToTrash(_ id: String) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].mailbox = .trash
    }

    func reply(to thread: MailThread, allRecipients: Bool = false) -> ComposeDraft {
        ComposeDraft.reply(to: thread, accountEmail: Self.accountEmail, allRecipients: allRecipients)
    }

    func forward(_ thread: MailThread) -> ComposeDraft { ComposeDraft.forward(thread) }

    func saveDraft(_ draft: ComposeDraft) {
        guard draft.hasContent else { return }
        var saved = draft
        saved.updatedAt = Date()
        if let index = drafts.firstIndex(where: { $0.id == saved.id }) {
            drafts[index] = saved
        } else {
            drafts.append(saved)
        }
    }

    func deleteDraft(_ id: String) {
        drafts.removeAll { $0.id == id }
    }

    // No network call: this only adds a message to the in-memory demo mailbox.
    @discardableResult
    func sendDemo(_ draft: ComposeDraft) -> String? {
        guard draft.canSend else { return nil }
        let message = MailMessage(
            id: UUID().uuidString,
            senderName: Self.accountName,
            senderEmail: Self.accountEmail,
            recipient: draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            cc: draft.cc.trimmingCharacters(in: .whitespacesAndNewlines),
            date: Date(),
            body: draft.body
        )
        let sent = MailThread(id: UUID().uuidString, subject: draft.subject, messages: [message], mailbox: .sent)
        threads.append(sent)
        if let index = threads.firstIndex(where: { $0.id == draft.replyingTo }) {
            threads[index].messages.append(message)
        }
        deleteDraft(draft.id)
        return sent.id
    }
}
