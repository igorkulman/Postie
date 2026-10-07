import Foundation
import Network
import Observation
import os

/// A message waiting to be sent. Attachments are not part of the item: they are files next to it.
nonisolated struct OutboxItem: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, sending, failed }

    struct Attachment: Codable, Equatable, Sendable {
        var filename: String
        /// The name of the copy kept in the item's folder.
        var storedName: String
    }

    var id: String
    var accountID: String
    /// Fixed when the message is queued, so a retry can tell whether an earlier attempt got through.
    var messageID: String
    var createdAt: Date
    var state: State = .queued
    var attempts = 0
    var nextAttempt: Date?
    var lastError: String?
    var recipient: String
    var cc: String
    var bcc: String
    var subject: String
    var body: String
    var html: String?
    var threadID: String?
    var draftID: String?
    var kind: ComposeKind
    var attachments: [Attachment] = []
}

/// The outbox on disk: one folder per message with its `item.json` and attachment files.
/// Mail waiting to go out is the person's own work, so it lives apart from the mail cache that can be thrown away.
actor OutboxStore {
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Postie", directoryHint: .isDirectory)
            .appending(path: "Outbox", directoryHint: .isDirectory)
    }

    func all() -> [OutboxItem] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> OutboxItem? in
            guard let data = try? Data(contentsOf: folder.appending(path: "item.json")) else { return nil }
            return try? Self.decoder.decode(OutboxItem.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes the item, first copying `files` next to it. Nothing is left behind when that fails.
    func add(_ item: OutboxItem, copying files: [(source: URL, storedName: String)]) throws {
        let folder = folder(for: item.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for file in files {
                let scoped = file.source.startAccessingSecurityScopedResource()
                defer { if scoped { file.source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: file.source, to: folder.appending(path: file.storedName))
            }
            try write(item)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func update(_ item: OutboxItem) throws {
        guard FileManager.default.fileExists(atPath: folder(for: item.id).path) else { return }
        try write(item)
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    func attachmentURLs(for item: OutboxItem) -> [URL] {
        item.attachments.map { folder(for: item.id).appending(path: $0.storedName) }
    }

    /// Moves the attachments out of the item's folder, for a message that goes back to the composer.
    func moveAttachments(of item: OutboxItem, to destination: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return try item.attachments.map { attachment in
            let target = destination.appending(path: attachment.filename)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: folder(for: item.id).appending(path: attachment.storedName), to: target)
            return target
        }
    }

    private func folder(for id: String) -> URL {
        root.appending(path: id, directoryHint: .isDirectory)
    }

    private func write(_ item: OutboxItem) throws {
        try Self.encoder.encode(item).write(to: folder(for: item.id).appending(path: "item.json"), options: [.atomic, .completeFileProtection])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// How a failed attempt should go on.
nonisolated enum OutboxFailure: Equatable {
    /// Worth trying again later: no connection, Gmail having trouble, or the account needing to sign in.
    case transient
    /// Retrying would give the same answer, so the message waits for the person.
    case permanent

    static func classify(_ error: Error) -> OutboxFailure {
        if error is URLError { return .transient }
        switch error as? GmailError {
        case .signInRequired, .permissionRequired: return .transient
        case .http(let code): return code == 401 || code == 408 || code == 429 || code >= 500 ? .transient : .permanent
        case .invalidResponse: return .transient
        case nil: return .permanent
        }
    }
}

/// Sends the queued messages one account at a time, in the order they were written, and keeps trying
/// when Gmail cannot be reached. A message that can never go out stays as failed until the person acts on it.
@MainActor
@Observable
final class Outbox {
    private(set) var items: [OutboxItem] = []
    /// Bumped on every change, so merged lists can tell when to rebuild.
    private(set) var revision = 0

    @ObservationIgnored private let store: OutboxStore
    @ObservationIgnored private let deliver: @MainActor (OutboxItem) async throws -> Void
    @ObservationIgnored private let canSend: @MainActor (String) -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let giveUpAfter: TimeInterval
    @ObservationIgnored private var working: Set<String> = []
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?

    init(store: OutboxStore = OutboxStore(), giveUpAfter: TimeInterval = 24 * 3600, now: @escaping @MainActor () -> Date = { Date() },
         canSend: @escaping @MainActor (String) -> Bool = { _ in true },
         deliver: @escaping @MainActor (OutboxItem) async throws -> Void) {
        self.store = store
        self.giveUpAfter = giveUpAfter
        self.now = now
        self.canSend = canSend
        self.deliver = deliver
    }

    var failedCount: Int { items.filter { $0.state == .failed }.count }

    /// Reads what an earlier run left behind. An attempt that was cut short counts as not yet made.
    func load() async {
        var loaded = await store.all()
        for index in loaded.indices where loaded[index].state == .sending {
            loaded[index].state = .queued
            try? await store.update(loaded[index])
        }
        items = loaded
        revision += 1
        kick()
    }

    func item(_ id: String) -> OutboxItem? { items.first { $0.id == id } }

    /// Queues a message and starts sending it. Throws when its attachments cannot be kept.
    func enqueue(_ draft: ComposeDraft, accountID: String) async throws {
        let id = UUID().uuidString
        var files: [(source: URL, storedName: String)] = []
        var attachments: [OutboxItem.Attachment] = []
        var total = 0
        for (index, url) in draft.attachments.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard total <= OutgoingAttachments.maxTotalBytes else { throw OutgoingAttachments.TooLarge() }
            let stored = "\(index)-\(url.lastPathComponent)"
            files.append((url, stored))
            attachments.append(.init(filename: url.lastPathComponent, storedName: stored))
        }
        let item = OutboxItem(
            id: id, accountID: accountID, messageID: "\(UUID().uuidString)@postie.local", createdAt: now(),
            recipient: draft.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
            cc: draft.cc.trimmingCharacters(in: .whitespacesAndNewlines),
            bcc: draft.bcc.trimmingCharacters(in: .whitespacesAndNewlines),
            subject: draft.subject, body: draft.body, html: draft.html, threadID: draft.gmailThreadID,
            draftID: draft.gmailDraftID, kind: draft.kind, attachments: attachments
        )
        try await store.add(item, copying: files)
        items.append(item)
        revision += 1
        kick()
    }

    func attachmentURLs(for item: OutboxItem) async -> [URL] { await store.attachmentURLs(for: item) }

    /// Tries a failed or waiting message again right away.
    func retry(_ id: String) {
        guard var item = item(id), item.state != .sending else { return }
        item.state = .queued
        item.nextAttempt = nil
        item.lastError = nil
        Task {
            await replace(item)
            kick()
        }
    }

    /// Takes a message out of the outbox, unless it is being sent right now.
    func remove(_ id: String) async {
        guard let item = item(id), item.state != .sending else { return }
        items.removeAll { $0.id == id }
        revision += 1
        await store.remove(id)
    }

    /// Takes a message out of the outbox to be edited. Its attachments are moved to `folder`.
    func take(_ id: String, attachmentsTo folder: URL) async throws -> (OutboxItem, [URL])? {
        guard let item = item(id), item.state != .sending else { return nil }
        let urls = try await store.moveAttachments(of: item, to: folder)
        items.removeAll { $0.id == id }
        revision += 1
        await store.remove(id)
        return (item, urls)
    }

    /// Drops everything queued for an account that is being removed.
    func removeAll(accountID: String) async {
        for item in items where item.accountID == accountID { await store.remove(item.id) }
        items.removeAll { $0.accountID == accountID }
        revision += 1
    }

    /// Looks for messages that are due, for whatever reason: something was queued, the network came back, an account signed in.
    func kick() {
        let due = Set(items.filter { isDue($0) }.map(\.accountID))
        for accountID in due where !working.contains(accountID) {
            working.insert(accountID)
            Task { await drain(accountID) }
        }
        scheduleWake()
    }

    func startMonitoringNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kick() }
        }
        monitor.start(queue: DispatchQueue(label: "postie.outbox.network"))
        self.monitor = monitor
    }

    private func isDue(_ item: OutboxItem) -> Bool {
        item.state == .queued && (item.nextAttempt ?? .distantPast) <= now() && canSend(item.accountID)
    }

    private func drain(_ accountID: String) async {
        defer { working.remove(accountID); scheduleWake() }
        while let item = items.first(where: { $0.accountID == accountID && isDue($0) }) {
            await attempt(item)
        }
    }

    private func attempt(_ queued: OutboxItem) async {
        var item = queued
        item.state = .sending
        item.attempts += 1
        await replace(item)
        do {
            try await deliver(item)
            items.removeAll { $0.id == item.id }
            revision += 1
            await store.remove(item.id)
            Log.api.info("Sent a queued message")
        } catch is CancellationError {
            item.state = .queued
            item.attempts -= 1
            await replace(item)
        } catch {
            Log.api.error("Could not send a queued message: \(error.localizedDescription, privacy: .public)")
            item.lastError = error.localizedDescription
            if OutboxFailure.classify(error) == .transient, now().timeIntervalSince(item.createdAt) < giveUpAfter {
                item.state = .queued
                item.nextAttempt = now().addingTimeInterval(Self.delay(afterAttempt: item.attempts))
            } else {
                item.state = .failed
                item.nextAttempt = nil
            }
            await replace(item)
        }
    }

    /// 30 seconds, then ever longer, up to an hour.
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(30 * pow(4, Double(max(attempt - 1, 0))), 3600)
    }

    private func replace(_ item: OutboxItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        revision += 1
        try? await store.update(item)
    }

    /// Wakes up when the next waiting message becomes due.
    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        let times = items.filter { $0.state == .queued && canSend($0.accountID) }.compactMap(\.nextAttempt)
        guard let next = times.min() else { return }
        let wait = max(next.timeIntervalSince(now()), 1)
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            self?.kick()
        }
    }
}
