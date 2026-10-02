import CoreServices
import Foundation

/// Downloaded attachments live in the caches folder, one folder per file so names never collide.
nonisolated enum AttachmentFiles {
    private static var root: URL {
        URL.cachesDirectory.appending(path: "Postie", directoryHint: .isDirectory)
            .appending(path: "Attachments", directoryHint: .isDirectory)
    }

    static func url(for attachment: MailAttachment, accountID: String) -> URL {
        root.appending(path: component(accountID), directoryHint: .isDirectory)
            .appending(path: component(attachment.id), directoryHint: .isDirectory)
            .appending(path: fileName(attachment.filename), directoryHint: .notDirectory)
    }

    static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the file and marks it as downloaded from the internet, so Gatekeeper vets it like a Mail attachment.
    @concurrent
    static func store(_ data: Data, at url: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // Write under a temporary name so a half-written file is never opened.
        let partial = url.deletingLastPathComponent().appending(path: UUID().uuidString)
        try data.write(to: partial, options: .completeFileProtection)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String,
            kLSQuarantineAgentNameKey as String: "Postie"
        ]
        var target = partial
        try? target.setResourceValues(values)
        try fileManager.moveItem(at: partial, to: url)
    }

    /// Deleting an account's files can take a moment, so it happens off the main actor.
    @concurrent
    static func removeAll(accountID: String) async {
        try? FileManager.default.removeItem(at: root.appending(path: component(accountID), directoryHint: .isDirectory))
    }

    /// A name from a sender must not be able to leave its folder or hide.
    static func fileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let visible = cleaned.drop { $0 == "." }
        return visible.isEmpty ? "attachment" : String(visible)
    }

    private static func component(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" }.prefix(120))
    }
}
