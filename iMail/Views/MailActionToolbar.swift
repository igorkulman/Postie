import SwiftUI

struct MailActionToolbar: View {
    @Binding var searchText: String
    let canArchive: Bool
    let canDelete: Bool
    let canRespond: Bool
    let deletingDraft: Bool
    let archive: () -> Void
    let delete: () -> Void
    let reply: () -> Void
    let replyAll: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ControlGroup {
                Button(action: archive) {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(!canArchive)
                .help("Archive")
                Button(action: delete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!canDelete)
                .help(deletingDraft ? "Delete Draft" : "Move to Trash")
            }
            .controlGroupStyle(.navigation)

            ControlGroup {
                Button(action: reply) {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .help("Reply")
                Button(action: replyAll) {
                    Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                }
                .help("Reply All")
                Button(action: forward) {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                }
                .help("Forward")
            }
            .controlGroupStyle(.navigation)
            .disabled(!canRespond)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search current mailbox")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 90, idealWidth: 180, maxWidth: 220)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
    }
}
