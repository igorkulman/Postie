import Foundation

/// Unsynced work is kept separately from the disposable mailbox cache, including copies of attachments.
actor DraftRecoveryStore {
    nonisolated struct Entry: Codable, Sendable {
        let payload: Data
        let attachments: [URL]
    }

    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Postie/DraftRecovery", directoryHint: .isDirectory)
    }

    func all() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { folder in
            let file = folder.appending(path: "draft.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
        }
    }

    @discardableResult
    func save(id: String, payload: Data, attachments: [URL]) throws -> Entry {
        let folder = folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied: [URL] = []
        do {
            for source in attachments {
                let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appending(path: source.lastPathComponent)
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            let manifest = folder.appending(path: "draft.json")
            let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            let entry = Entry(payload: payload, attachments: copied)
            try JSONEncoder().encode(entry).write(to: manifest, options: [.atomic, .completeFileProtection])
            // Only remove the old attachment copies after the new manifest is durable.
            for url in previous?.attachments ?? [] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return entry
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            throw error
        }
    }

    func remove(id: String) throws {
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    private func folder(for id: String) -> URL {
        let safe = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return root.appending(path: safe, directoryHint: .isDirectory)
    }
}
