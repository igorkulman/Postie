import SwiftUI

struct MailUndoNotice: View {
    let operation: MailRemovalUndo
    let dismiss: () -> Void

    // Errors stay until dismissed or retried, and a running restore is never cut short.
    // Native Undo remains available after the notice disappears.
    private var timeout: Duration? {
        operation.error != nil || operation.isRestoring ? nil : .seconds(operation.isUndone ? 3 : 8)
    }

    var body: some View {
        MailStatusCard(message: operation.confirmation, timeout: timeout, dismiss: dismiss) {
            if operation.isRestoring {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(operation.error == nil ? Color.secondary : Color.orange)
            }
        } actions: {
            if !operation.isUndone {
                Button(operation.error == nil ? "Undo" : "Retry Undo") { operation.undo() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!operation.canUndo)
                    .help("Undo \(operation.actionName) (⌘Z)")
            }
        }
    }

    private var symbol: String {
        if operation.isUndone { return "arrow.uturn.backward" }
        if operation.error != nil { return "exclamationmark.triangle.fill" }
        return operation.archiving ? "archivebox.fill" : "trash.fill"
    }
}
