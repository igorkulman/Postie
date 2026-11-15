import SwiftUI

struct MailUndoNotice: View {
    let operation: MailRemovalUndo
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if operation.isRestoring { ProgressView().controlSize(.small) }
            Text(operation.confirmation)
                .lineLimit(2)
            Spacer(minLength: 8)
            if !operation.isUndone {
                Button(operation.error == nil ? "Undo" : "Retry Undo") { operation.undo() }
                    .disabled(!operation.canUndo)
                    .help("Undo \(operation.actionName) (⌘Z)")
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task(id: operation.isUndone) {
            // Errors stay until dismissed or retried. Native Undo remains available after the notice disappears.
            do { try await Task.sleep(for: .seconds(operation.isUndone ? 3 : 8)) } catch { return }
            if operation.error == nil, !operation.isRestoring { dismiss() }
        }
    }
}
