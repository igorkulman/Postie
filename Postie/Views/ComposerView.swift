import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @State private var draft: ComposeDraft
    /// What the draft looked like when the composer opened, so an untouched reply is not "changed".
    @State private var original: ComposeDraft
    /// Nil for real accounts: Gmail drafts are not synced yet, so only the demo can keep drafts.
    private let save: ((ComposeDraft) -> Void)?
    private let send: (ComposeDraft) async throws -> Void
    /// Connected Gmail accounts. Empty in the demo, which sends from the sample address.
    private let accounts: [SendingAccount]
    private let fromAddress: String
    private let isDemo: Bool
    private let suggestContacts: ContactLookup
    /// The signature for an account's messages as HTML, or nil. Nil account means the default one.
    private let signature: (String?) async -> String?
    @State private var isSending = false
    @State private var sendError: String?
    @State private var showsCc: Bool
    @State private var showsBcc: Bool
    @State private var choosesFiles = false
    @State private var isDropTarget = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    @State private var editorController = RichTextController()
    @FocusState private var focusedField: Field?

    init(draft: ComposeDraft, save: ((ComposeDraft) -> Void)?, send: @escaping (ComposeDraft) async throws -> Void,
         accounts: [SendingAccount] = [], fromAddress: String = MailStore.accountEmail, isDemo: Bool = true,
         suggestContacts: @escaping ContactLookup = { _, _ in [] },
         signature: @escaping (String?) async -> String? = { _ in nil }) {
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
        _showsCc = State(initialValue: !draft.cc.isEmpty)
        _showsBcc = State(initialValue: !draft.bcc.isEmpty)
        self.save = save
        self.send = send
        self.accounts = accounts
        self.fromAddress = fromAddress
        self.isDemo = isDemo
        self.suggestContacts = suggestContacts
        self.signature = signature
    }

    private var senderAddress: String {
        accounts.first { $0.id == draft.accountID }?.email ?? fromAddress
    }

    /// A reply goes out from the account that received the mail, so only new messages can change it.
    private var choosesSender: Bool { accounts.count > 1 && draft.kind == .newMessage }

    /// Whether there is anything worth asking about before closing.
    private var hasChanges: Bool { draft.hasContent && draft != original }

    private enum Field: Hashable {
        case recipient, cc, bcc, subject, body
    }

    var body: some View {
        VStack(spacing: 0) {
            if isDemo {
                topBar
                Divider()
            }
            header.zIndex(1)
            Divider()
            editor
            if !draft.attachments.isEmpty { attachmentStrip }
            if sendError != nil || isDemo { footer }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 440, idealHeight: 600)
        .navigationTitle(draft.subject.isEmpty ? draft.kind.title : draft.subject)
        .toolbar { if !isDemo { windowToolbar } }
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isDropTarget = $0 }
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .background {
            if !isDemo {
                Button("Close") { if hasChanges { confirmsDiscard = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction).hidden()
            }
        }
        .interactiveDismissDisabled(hasChanges || isSending)
        // Writing from another account means that account's signature.
        .onChange(of: draft.accountID) {
            guard !isDemo else { return }
            Task { await editorController.setSignature(await signature(draft.accountID)) }
        }
        .onAppear {
            // The rich editor takes the cursor itself once it has loaded.
            if draft.recipient.isEmpty { focusedField = .recipient } else if isDemo { focusedField = .body }
        }
        .alert("Discard these changes?", isPresented: $confirmsDiscard) {
            Button("Keep Writing", role: .cancel) {}
            Button("Discard Changes", role: .destructive) { dismiss() }
        } message: {
            Text(save == nil ? String(localized: "This message has not been sent.") : String(localized: "Use Save Draft to keep this message for the current demo session."))
        }
    }

    // MARK: Pieces

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { choosesFiles = true } label: { Label("Attach Files", systemImage: "paperclip") }
                .help("Attach Files")
                .disabled(isSending)
        }
        ToolbarItem(placement: .primaryAction) {
            SendButton(canSend: draft.canSend, isSending: isSending, action: sendMessage)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                choosesFiles = true
            } label: {
                Image(systemName: "paperclip").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Attach Files")
            .accessibilityLabel("Attach files")
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
            Button("Cancel") {
                if hasChanges { confirmsDiscard = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSending)
            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.white)
                    .background(draft.canSend && !isSending ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!draft.canSend || isSending)
            .keyboardShortcut(.return, modifiers: [.command])
            .help(isDemo ? String(localized: "Add to the sample Sent mailbox. Does not send real email.") : String(localized: "Send with Gmail (⌘↩)"))
            .accessibilityLabel(isDemo ? "Send demo message" : "Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var header: some View {
        VStack(spacing: 0) {
            FieldRow("To") {
                TextField("", text: $draft.recipient)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .recipient)
                    .accessibilityLabel("Recipient email address")
                HStack(spacing: 6) {
                    if !showsCc { RevealButton("Cc") { showsCc = true; focusedField = .cc } }
                    if !showsBcc { RevealButton("Bcc") { showsBcc = true; focusedField = .bcc } }
                }
            }
            .contactSuggestions(for: $draft.recipient, isFocused: focusedField == .recipient, accountID: draft.accountID, lookup: suggestContacts)
            if showsCc {
                FieldRow("Cc") {
                    TextField("", text: $draft.cc)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .cc)
                        .accessibilityLabel("CC email addresses")
                }
                .contactSuggestions(for: $draft.cc, isFocused: focusedField == .cc, accountID: draft.accountID, lookup: suggestContacts)
            }
            if showsBcc {
                FieldRow("Bcc") {
                    TextField("", text: $draft.bcc)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .bcc)
                        .accessibilityLabel("BCC email addresses")
                }
                .contactSuggestions(for: $draft.bcc, isFocused: focusedField == .bcc, accountID: draft.accountID, lookup: suggestContacts)
            }
            FieldRow("Subject") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .subject)
                    .accessibilityLabel("Subject")
            }
            FieldRow("From") {
                if choosesSender {
                    Picker("From", selection: $draft.accountID) {
                        ForEach(accounts) { account in
                            Text(account.email).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .fixedSize()
                } else {
                    Text(senderAddress).foregroundStyle(.primary)
                }
                Spacer(minLength: 0)
                if isDemo { DemoBadge() }
            }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var editor: some View {
        if isDemo {
            plainEditor
        } else {
            RichTextEditor(
                html: draft.html ?? "", controller: editorController, focusOnLoad: !draft.recipient.isEmpty,
                loaded: { content in
                    // The editor tidies the markup it was given. That is not a change the person made.
                    apply(content, to: &draft)
                    apply(content, to: &original)
                    Task { await addSignature() }
                },
                changed: { apply($0, to: &draft) },
                dropFiles: attach
            )
        }
    }

    /// Puts the account's Gmail signature in once the editor is ready. Adding it is not an edit the person made.
    private func addSignature() async {
        await editorController.setSignature(await signature(draft.accountID))
        if let content = await editorController.content() {
            apply(content, to: &draft)
            apply(content, to: &original)
        }
    }

    private func apply(_ content: EditorContent, to draft: inout ComposeDraft) {
        draft.html = content.html
        draft.body = content.text
        draft.ownText = content.ownText
    }

    private var plainEditor: some View {
        TextEditor(text: $draft.body)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focusedField, equals: .body)
            .accessibilityLabel("Message body")
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attachmentStrip: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.attachments, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(url.lastPathComponent).lineLimit(1)
                            Button {
                                draft.attachments.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(url.lastPathComponent)")
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Group {
                if let sendError {
                    Label(sendError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .onAppear { AccessibilityNotification.Announcement(sendError).post() }
                } else {
                    Text("Demo only. No email will be sent. Drafts disappear when you quit.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: Actions

    private func attach(_ urls: [URL]) {
        for url in urls where !draft.attachments.contains(url) { draft.attachments.append(url) }
    }

    private func sendMessage() {
        Task {
            isSending = true
            sendError = nil
            do {
                // The editor reports changes after a short pause; send what is on screen, not what was last reported.
                if !isDemo, let content = await editorController.content() { apply(content, to: &draft) }
                try await send(draft)
                dismiss()
            } catch {
                sendError = error.localizedDescription
            }
            isSending = false
        }
    }
}

/// The window toolbar's send button. It keeps its size while sending, so the toolbar does not shift.
private struct SendButton: View {
    let canSend: Bool
    let isSending: Bool
    let action: () -> Void

    var body: some View {
        // Not disabled while sending: the system would dim the spinner. A second tap does nothing instead.
        Button { if !isSending { action() } } label: {
            ZStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.white)
                    .opacity(isSending ? 0 : 1)
                if isSending {
                    SendSpinner().accessibilityLabel("Sending")
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        // Prominent buttons do not dim much when disabled, so say "nothing to send yet" with the colour.
        .tint(canSend || isSending ? Color.accentColor : Color.secondary.opacity(0.5))
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Send with Gmail (⌘↩)")
        .accessibilityLabel("Send")
    }
}

/// A white arc that turns, readable on the button's accent colour where the system spinner is not.
private struct SendSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: 16, height: 16)
    }
}

/// One labelled line of the composer's header, like To or Subject.
private struct FieldRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
            content
        }
        .padding(.vertical, 7)
    }
}

/// The small Cc and Bcc pills that reveal their rows.
private struct RevealButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

#Preview("Compose") {
    ComposerView(draft: ComposeDraft(), save: { _ in }, send: { _ in })
}

#Preview("Send button") {
    NavigationStack {
        Color.clear.frame(width: 360, height: 120)
            .toolbar { ToolbarItem(placement: .primaryAction) { SendButton(canSend: true, isSending: false) {} } }
    }
}

#Preview("Send button · disabled") {
    NavigationStack {
        Color.clear.frame(width: 360, height: 120)
            .toolbar { ToolbarItem(placement: .primaryAction) { SendButton(canSend: false, isSending: false) {} } }
    }
}

#Preview("Send button · sending") {
    NavigationStack {
        Color.clear.frame(width: 360, height: 120)
            .toolbar { ToolbarItem(placement: .primaryAction) { SendButton(canSend: true, isSending: true) {} } }
    }
}
