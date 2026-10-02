import SwiftUI

/// Launch with -PostieSelectionRegression to exercise the actual Gmail UI without a mailbox.
struct GmailSelectionRegressionView: View {
    @State private var mail: SelectionRegressionMail
    @State private var hub: MailHub?
    @State private var error: String?

    init(empty: Bool = false) {
        _mail = State(initialValue: SelectionRegressionMail(empty: empty))
    }

    fileprivate init(mail: SelectionRegressionMail, hub: MailHub) {
        _mail = State(initialValue: mail)
        _hub = State(initialValue: hub)
    }

    var body: some View {
        Group {
            if let hub {
                GmailInboxView(hub: hub)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Menu("Regression") {
                                Button("Insert Newer Mail") {
                                    mail.insertNewerMail()
                                    Task { await hub.refresh() }
                                }
                                Button("Archive Sample Thread Externally") {
                                    Task {
                                        do {
                                            try await mail.archive(threadID: "open")
                                            await hub.refresh()
                                        } catch { self.error = error.localizedDescription }
                                    }
                                }
                                Toggle("Reject Next Archive or Trash", isOn: $mail.rejectNextRemoval)
                            }
                        }
                    }
            } else if let error {
                ContentUnavailableView("Could Not Open Regression Mail", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("Opening regression mail…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Regression Action Failed", isPresented: Binding(
            get: { hub != nil && error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task {
            guard hub == nil else { return }
            do { hub = try await mail.makeHub() }
            catch { self.error = error.localizedDescription }
        }
    }
}

// Prepare SQLite before snapshotting; a view's asynchronous .task otherwise snapshots only its spinner.
private struct RegressionPreviewData: PreviewModifier {
    let empty: Bool

    struct Context {
        let mail: SelectionRegressionMail
        let hub: MailHub
        let emptyMail: SelectionRegressionMail
        let emptyHub: MailHub
    }

    static func makeSharedContext() async throws -> Context {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        await hub.select(hub.conversations.first?.key)
        let emptyMail = SelectionRegressionMail(empty: true)
        let emptyHub = try await emptyMail.makeHub()
        return Context(mail: mail, hub: hub, emptyMail: emptyMail, emptyHub: emptyHub)
    }

    func body(content: Content, context: Context) -> some View {
        GmailSelectionRegressionView(mail: empty ? context.emptyMail : context.mail,
                                     hub: empty ? context.emptyHub : context.hub)
            .frame(width: empty ? 960 : 1200, height: empty ? 640 : 820)
    }
}

#Preview("Selection Regression", traits: .modifier(RegressionPreviewData(empty: false))) {
    Color.clear
}

#Preview("Empty Inbox", traits: .modifier(RegressionPreviewData(empty: true))) {
    Color.clear
}
