import SwiftUI

struct ComposerView: View {
    @State var draft: ComposeDraft
    /// Nil for real accounts: Gmail drafts are not synced yet, so only the demo can keep drafts.
    let save: ((ComposeDraft) -> Void)?
    let send: (ComposeDraft) async throws -> Void
    /// Connected Gmail accounts. Empty in the demo, which sends from the sample address.
    var accounts: [SendingAccount] = []
    var fromAddress = MailStore.accountEmail
    var isDemo = true
    @State private var isSending = false
    @State private var sendError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    @FocusState private var focusedField: Field?

    private var senderAddress: String {
        accounts.first { $0.id == draft.accountID }?.email ?? fromAddress
    }

    /// A reply goes out from the account that received the mail, so only new messages can change it.
    private var choosesSender: Bool { accounts.count > 1 && draft.kind == .newMessage }

    private enum Field: Hashable {
        case recipient, cc, subject, body
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.kind.title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if isDemo { DemoBadge() }
            }
            .padding(24)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text("From").foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        .accessibilityHidden(choosesSender)
                    if choosesSender {
                        Picker("From", selection: $draft.accountID) {
                            ForEach(accounts) { account in
                                Text(account.email).tag(Optional(account.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(senderAddress).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .accessibilityElement(children: choosesSender ? .contain : .combine)
                .padding(.vertical, 13)
                Divider()
                HStack {
                    Text("To").foregroundStyle(.secondary).frame(width: 52, alignment: .leading).accessibilityHidden(true)
                    TextField("name@example.com", text: $draft.recipient)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .recipient)
                        .accessibilityLabel("Recipient email address")
                }
                .padding(.vertical, 13)
                Divider()
                HStack {
                    Text("Cc").foregroundStyle(.secondary).frame(width: 52, alignment: .leading).accessibilityHidden(true)
                    TextField("Optional · separate addresses with commas", text: $draft.cc)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .cc)
                        .accessibilityLabel("CC email addresses")
                }
                .padding(.vertical, 13)
                Divider()
                HStack {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 52, alignment: .leading).accessibilityHidden(true)
                    TextField("A good subject goes a long way", text: $draft.subject)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .subject)
                        .accessibilityLabel("Subject")
                }
                .padding(.vertical, 13)
                Divider()
            }
            .font(.body)
            .padding(.horizontal, 24)

            ZStack(alignment: .topLeading) {
                if draft.body.isEmpty {
                    Text("Write something thoughtful…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 9)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft.body)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .body)
                    .accessibilityLabel("Message body")
            }
            .font(.system(size: 14))
            .padding(20)
            .frame(minHeight: 230)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let sendError {
                    Label(sendError, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .onAppear { AccessibilityNotification.Announcement(sendError).post() }
                } else if isDemo {
                    Text("Demo only. No email will be sent. Drafts disappear when you quit.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") {
                        if draft.hasContent {
                            confirmsDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSending)
                    if let save {
                        Button("Save Draft") {
                            save(draft)
                            dismiss()
                        }
                        .disabled(!draft.hasContent || isSending)
                    }
                    Spacer()
                    if isSending { ProgressView().controlSize(.small).accessibilityLabel("Sending") }
                    Button {
                        Task {
                            isSending = true
                            sendError = nil
                            do {
                                try await send(draft)
                                dismiss()
                            } catch {
                                sendError = error.localizedDescription
                            }
                            isSending = false
                        }
                    } label: {
                        Label(isDemo ? String(localized: "Send Demo") : String(localized: "Send"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.canSend || isSending)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(isDemo ? String(localized: "Add to the sample Sent mailbox. Does not send real email.") : String(localized: "Send with Gmail (⌘↩)"))
                }
                .controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 620, height: 620)
        .interactiveDismissDisabled(draft.hasContent || isSending)
        .onAppear { focusedField = draft.recipient.isEmpty ? .recipient : .body }
        .alert("Discard these changes?", isPresented: $confirmsDiscard) {
            Button("Keep Writing", role: .cancel) {}
            Button("Discard Changes", role: .destructive) { dismiss() }
        } message: {
            Text(save == nil ? String(localized: "This message has not been sent.") : String(localized: "Use Save Draft to keep this message for the current demo session."))
        }
    }
}

#Preview("Compose") {
    ComposerView(draft: ComposeDraft(), save: { _ in }, send: { _ in })
}
