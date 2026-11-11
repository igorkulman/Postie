import Foundation
import Observation
import Testing
@testable import Postie

@Suite("Automatic read state", .timeLimit(.minutes(1)))
@MainActor
struct InboxAutoReadTests {
    private let key = ConversationKey(accountID: "a", threadID: "unread")
    private let neighbor = ConversationKey(accountID: "a", threadID: "read")

    private func makeInbox(isReaderActive: Bool = true,
                           autoReadDelay: @escaping @MainActor () async throws -> Void = {}) async -> (InboxModel, AutoReadAPI) {
        let api = AutoReadAPI([
            MailHubTests.conversation("unread", at: 200, unread: true),
            MailHubTests.conversation("read", at: 100)
        ])
        let hub = await MailHubTests().makeHub(["a": api])
        let model = InboxModel(hub: hub, autoReadDelay: autoReadDelay)
        model.setReaderActive(isReaderActive)
        model.select(key)
        return (model, api)
    }

    // Observe real reader state so the old fire-and-forget mutation can finish without test sleeps.
    private func waitUntil(_ condition: () -> Bool) async {
        while !Task.isCancelled {
            let (events, changed) = AsyncStream.makeStream(of: Void.self)
            let done = withObservationTracking { condition() } onChange: {
                changed.yield()
                changed.finish()
            }
            if done { return }
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    @Test("Reopening unread mail marks it read even when the intervening conversation was already read")
    func reopenedConversation() async throws {
        let (model, api) = await makeInbox()
        await model.openSelection()
        await waitUntil { model.hub.conversation(for: key)?.isUnread == false }
        await model.hub.setUnread(key, true)

        // Exercise the binding used by the real List, not just programmatic selection.
        model.updateFromList(neighbor)
        await model.openSelection()
        model.updateFromList(key)
        await model.openSelection()

        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(model.hub.openConversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false, true, false])
        #expect(api.changes.allSatisfy { $0.label == "UNREAD" && $0.id == "unread" })
    }

    @Test("A failed automatic read can be retried while the same conversation stays selected")
    func rejectedReadCanRetry() async throws {
        let (model, api) = await makeInbox()
        api.rejectNextChange = true
        await model.openSelection()
        await waitUntil { model.hub.sessions.first?.reader.mailboxError != nil }
        #expect(model.hub.conversation(for: key)?.isUnread == true)

        model.retry()
        #expect(model.selectionRetry == 1)
        await model.openSelection()

        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(model.hub.openConversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false, false])
    }

    @Test("Explicitly marking the open conversation unread survives refreshes, but not reopening")
    func manualUnreadIsPreservedForThisOpening() async throws {
        let (model, api) = await makeInbox()
        await model.openSelection()
        await waitUntil { model.hub.conversation(for: key)?.isUnread == false }
        let item = try #require(model.hub.list[key])
        model.toggleRead(item)
        await waitUntil { model.hub.conversation(for: key)?.isUnread == true }

        model.setReaderActive(false)
        model.setReaderActive(true)
        await model.hub.refresh()
        await model.openSelection()
        #expect(model.hub.conversation(for: key)?.isUnread == true)
        #expect(api.changes.map(\.on) == [false, true])

        model.updateFromList(nil)
        model.updateFromList(key)
        await model.openSelection()
        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false, true, false])
    }

    @Test("A new unread update in the open conversation is not blocked by an earlier successful auto-read")
    func newlyUnreadOpenConversation() async {
        let (model, api) = await makeInbox()
        await model.openSelection()
        await waitUntil { model.hub.conversation(for: key)?.isUnread == false }

        api.markUnreadOnServer("unread")
        await model.hub.refresh()
        await model.openSelection()

        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false, false])
    }

    @Test("An inactive reader never automatically marks an opened conversation read")
    func inactiveOpening() async {
        let (model, api) = await makeInbox(isReaderActive: false)
        await model.openSelection()

        #expect(model.hub.openConversation(for: key)?.isUnread == true)
        #expect(api.changes.isEmpty)
    }

    @Test("A reply arriving in the background stays unread until the reader becomes active")
    func backgroundReply() async {
        let (model, api) = await makeInbox()
        await model.openSelection()
        model.setReaderActive(false)

        api.markUnreadOnServer("unread")
        await model.hub.refresh()
        await model.openSelection()

        #expect(model.hub.conversation(for: key)?.isUnread == true)
        #expect(api.changes.map(\.on) == [false])

        model.setReaderActive(true)
        await model.openSelection()
        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false, false])
    }

    @Test("Leaving the reader invalidates its countdown, even if it becomes active again", arguments: [false, true])
    func deactivationDuringCountdown(reactivateBeforeCompletion: Bool) async {
        let countdown = AutoReadCountdown()
        let (model, api) = await makeInbox(autoReadDelay: countdown.wait)
        let opening = Task { await model.openSelection() }
        await countdown.waitForStart()

        model.setReaderActive(false)
        if reactivateBeforeCompletion { model.setReaderActive(true) }
        countdown.release()
        await opening.value

        #expect(model.hub.conversation(for: key)?.isUnread == true)
        #expect(api.changes.isEmpty)

        // Returning starts a fresh countdown rather than completing the interrupted one.
        model.setReaderActive(true)
        await model.openSelection()
        #expect(model.hub.conversation(for: key)?.isUnread == false)
        #expect(api.changes.map(\.on) == [false])
    }

    @Test("Cancelled openings never mark mail read")
    func cancelledOpening() async {
        let (model, api) = await makeInbox()
        let opening = Task { await model.openSelection() }
        opening.cancel()
        await opening.value
        #expect(model.hub.conversation(for: key)?.isUnread == true)
        #expect(api.changes.isEmpty)
    }
}

/// Only simulates Gmail's label endpoint; auto-read decisions run through InboxModel and MailHub.
@MainActor
private final class AutoReadAPI: GmailReading, GmailMutating {
    struct Change {
        let label: String
        let on: Bool
        let id: String
    }

    private var mail: [GmailConversation]
    private(set) var changes: [Change] = []
    var rejectNextChange = false

    init(_ mail: [GmailConversation]) { self.mail = mail }

    @MainActor func mailbox(_ mailbox: Mailbox, pageToken: String?) async throws -> GmailPage {
        GmailPage(conversations: mail, nextPageToken: nil)
    }
    @MainActor func conversation(id: String) async throws -> GmailConversation {
        guard let conversation = mail.first(where: { $0.id == id }) else { throw GmailError.http(404) }
        return conversation
    }
    @MainActor func unreadInboxCount() async throws -> Int { mail.filter(\.isUnread).count }

    func markUnreadOnServer(_ id: String) {
        guard let index = mail.firstIndex(where: { $0.id == id }) else { return }
        mail[index] = mail[index].setting("UNREAD", to: true)
    }
    func archive(threadID: String) async throws {}
    func trash(threadID: String) async throws {}

    @MainActor func setLabel(_ label: String, on: Bool, threadID: String) async throws {
        changes.append(Change(label: label, on: on, id: threadID))
        if rejectNextChange {
            rejectNextChange = false
            throw GmailError.http(503)
        }
        guard let index = mail.firstIndex(where: { $0.id == threadID }) else { throw GmailError.http(404) }
        mail[index] = mail[index].setting(label, to: on)
    }
}
