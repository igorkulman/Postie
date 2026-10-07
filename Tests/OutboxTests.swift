import Foundation
import Testing
@testable import Postie

@Suite("Outbox", .timeLimit(.minutes(1)))
@MainActor
struct OutboxTests {
    private func temporaryRoot() -> URL {
        URL.temporaryDirectory.appending(path: "PostieOutboxTests-" + UUID().uuidString, directoryHint: .isDirectory)
    }

    private func draft(_ subject: String = "Hi") -> ComposeDraft {
        ComposeDraft(recipient: "x@example.com", subject: subject, body: "Hello", accountID: "a")
    }

    private func settle(_ outbox: Outbox, until done: (Outbox) -> Bool) async throws {
        for _ in 0..<500 where !done(outbox) { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("A queued message is delivered and then removed from disk")
    func delivers() async throws {
        let root = temporaryRoot()
        var delivered: [OutboxItem] = []
        let outbox = Outbox(store: OutboxStore(root: root)) { delivered.append($0) }
        try await outbox.enqueue(draft(), accountID: "a")
        try await settle(outbox) { $0.items.isEmpty }
        #expect(delivered.map(\.subject) == ["Hi"])
        #expect(await OutboxStore(root: root).all().isEmpty)
    }

    @Test("A message survives a restart and is sent by the next run")
    func survivesRestart() async throws {
        let root = temporaryRoot()
        let first = Outbox(store: OutboxStore(root: root), canSend: { _ in false }) { _ in }
        try await first.enqueue(draft("Later"), accountID: "a")
        #expect(first.items.count == 1)
        var delivered: [String] = []
        let second = Outbox(store: OutboxStore(root: root)) { delivered.append($0.subject) }
        await second.load()
        try await settle(second) { $0.items.isEmpty }
        #expect(delivered == ["Later"])
    }

    @Test("An attempt cut short by quitting is made again")
    func resetsSending() async throws {
        let root = temporaryRoot()
        let store = OutboxStore(root: root)
        let blocked = Outbox(store: store, canSend: { _ in false }) { _ in }
        try await blocked.enqueue(draft(), accountID: "a")
        var item = try #require(blocked.items.first)
        item.state = .sending
        try await store.update(item)
        let next = Outbox(store: store, canSend: { _ in false }) { _ in }
        await next.load()
        #expect(next.items.first?.state == .queued)
    }

    @Test("Attachments are copied next to the message")
    func attachments() async throws {
        let root = temporaryRoot()
        let source = URL.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        try Data("file".utf8).write(to: source)
        var message = draft()
        message.attachments = [source]
        let store = OutboxStore(root: root)
        let outbox = Outbox(store: store, canSend: { _ in false }) { _ in }
        try await outbox.enqueue(message, accountID: "a")
        let item = try #require(outbox.items.first)
        let urls = await store.attachmentURLs(for: item)
        #expect(try Data(contentsOf: urls[0]) == Data("file".utf8))
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
    }

    @Test("A temporary failure is retried later, a permanent one waits for the person")
    func failures() async throws {
        var calls = 0
        let outbox = Outbox(store: OutboxStore(root: temporaryRoot())) { _ in
            calls += 1
            throw calls == 1 ? GmailError.http(503) : GmailError.http(400)
        }
        try await outbox.enqueue(draft(), accountID: "a")
        try await settle(outbox) { $0.items.first?.attempts == 1 && $0.items.first?.state == .queued }
        let waiting = try #require(outbox.items.first)
        #expect(waiting.nextAttempt != nil)
        outbox.retry(waiting.id)
        try await settle(outbox) { $0.items.first?.state == .failed }
        #expect(outbox.items.first?.state == .failed)
        #expect(outbox.failedCount == 1)
        #expect(calls == 2)
    }

    @Test("Failures are told apart")
    func classification() {
        #expect(OutboxFailure.classify(URLError(.notConnectedToInternet)) == .transient)
        #expect(OutboxFailure.classify(GmailError.http(429)) == .transient)
        #expect(OutboxFailure.classify(GmailError.http(500)) == .transient)
        #expect(OutboxFailure.classify(GmailError.signInRequired) == .transient)
        #expect(OutboxFailure.classify(GmailError.http(400)) == .permanent)
        #expect(OutboxFailure.classify(OutgoingAttachments.TooLarge()) == .permanent)
    }

    @Test("The wait between attempts grows up to an hour")
    func backoff() {
        #expect(Outbox.delay(afterAttempt: 1) == 30)
        #expect(Outbox.delay(afterAttempt: 2) == 120)
        #expect(Outbox.delay(afterAttempt: 9) == 3600)
    }

    @Test("A message taken for editing leaves the outbox with its attachments")
    func take() async throws {
        let outbox = Outbox(store: OutboxStore(root: temporaryRoot()), canSend: { _ in false }) { _ in }
        try await outbox.enqueue(draft(), accountID: "a")
        let id = try #require(outbox.items.first?.id)
        let taken = try await outbox.take(id, attachmentsTo: temporaryRoot())
        #expect(taken?.0.subject == "Hi")
        #expect(outbox.items.isEmpty)
    }
}
