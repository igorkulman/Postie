import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Downloads an attachment, if needed, and returns the local file. It is a value, not a closure, so the
/// environment can tell when it changed. Absent when mail isn't connected (demo mode).
nonisolated struct AttachmentLoader: Equatable, Sendable {
    let hub: MailHub
    let accountID: String

    func callAsFunction(_ attachment: MailAttachment) async throws -> URL {
        try await hub.attachmentFile(attachment, accountID: accountID)
    }

    static func == (lhs: AttachmentLoader, rhs: AttachmentLoader) -> Bool {
        lhs.hub === rhs.hub && lhs.accountID == rhs.accountID
    }
}

extension EnvironmentValues {
    @Entry var attachmentLoader: AttachmentLoader? = nil
}

/// Icons are looked up per file type, not per file, and kept: a list can show hundreds of rows.
private func fileIcon(for filename: String) -> NSImage {
    let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    return FileIconCache.icon(for: type)
}

private enum FileIconCache {
    private static var icons: [UTType: NSImage] = [:]

    static func icon(for type: UTType) -> NSImage {
        if let icon = icons[type] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type] = icon
        return icon
    }
}

/// What the share sheet and drag and drop receive: the file itself, downloaded only when it's actually used.
nonisolated private struct AttachmentFile: Transferable, Sendable {
    let name: String
    let load: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(try await file.load(), allowAccessingOriginalFile: false)
        }
        .suggestedFileName { $0.name }
    }
}

/// The attachments of one message, shown as the last rows of its header like Mimestream does.
struct AttachmentList: View {
    let attachments: [MailAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { AttachmentRow(attachment: $0, all: attachments) }
        }
    }
}

private struct AttachmentRow: View {
    let attachment: MailAttachment
    let all: [MailAttachment]
    @Environment(\.attachmentLoader) private var loader
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: fileIcon(for: attachment.filename))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(attachment.filename)
                .lineLimit(1)
                .truncationMode(.middle)
            if attachment.size > 0 {
                Text(verbatim: Int64(attachment.size).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        // A single click does nothing; opening takes a double click.
        .onTapGesture(count: 2, perform: open)
        .draggable(file)
        .contextMenu {
            Button("Open", action: open)
            Button("Save As…", action: save)
            if all.count > 1 {
                Button("Save All…", action: saveAll)
            }
            ShareLink(item: file, preview: SharePreview(attachment.filename))
            Button("Copy", action: copy)
        }
        .disabled(loader == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Attachment \(attachment.filename)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Open"), open)
        .accessibilityAction(named: Text("Save As…"), save)
        .alert("Could Not Open Attachment", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var file: AttachmentFile {
        let loader = loader, attachment = attachment
        return AttachmentFile(name: attachment.filename) {
            guard let loader else { throw GmailError.permissionRequired }
            return try await loader(attachment)
        }
    }

    private func open() {
        work { url in NSWorkspace.shared.open(url) }
    }

    private func save() {
        work { url in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = attachment.filename
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    private func saveAll() {
        guard let loader, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save")
        isWorking = true
        Task {
            defer { isWorking = false }
            guard await panel.begin() == .OK, let folder = panel.url else { return }
            do {
                for item in all {
                    let source = try await loader(item)
                    try FileManager.default.copyItem(at: source, to: unusedURL(for: item.filename, in: folder))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copy() {
        work { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
    }

    private func work(_ action: @escaping @MainActor (URL) async throws -> Void) {
        guard let loader, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await action(try await loader(attachment)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    /// Never overwrite a file that is already in the chosen folder.
    private func unusedURL(for name: String, in folder: URL) -> URL {
        let safe = AttachmentFiles.fileName(name)
        var candidate = folder.appending(path: safe, directoryHint: .notDirectory)
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)", directoryHint: .notDirectory)
            index += 1
        }
        return candidate
    }
}

/// The first attachment of a conversation's newest message, plus how many more there are, for the message list.
struct AttachmentChip: View {
    let attachments: [MailAttachment]

    var body: some View {
        if let first = attachments.first {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(nsImage: fileIcon(for: first.filename))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(first.filename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                if attachments.count > 1 {
                    Text("& \(attachments.count - 1) more", comment: "After the first attachment's name in the message list")
                        .fixedSize()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}
