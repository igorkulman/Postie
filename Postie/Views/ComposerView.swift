import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @State private var draft: ComposeDraft
    /// What the draft looked like when the composer opened, so an untouched reply is not "changed".
    @State private var original: ComposeDraft
    /// Keeps the message as a Gmail draft while it is written.
    @State private var session: DraftSession
    @State private var closeGuard = CloseGuard()
    @State private var asksToKeep = false
    @State private var editorReady = false
    @State private var signatureRequestID = UUID()
    @State private var isClosing = false
    private let recoversLocalDraft: Bool
    private let send: (ComposeDraft) async throws -> Void
    private let accounts: [SendingAccount]
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
    @State private var editorController = RichTextController()
    @FocusState private var focusedField: Field?

    init(draft: ComposeDraft, drafts: DraftStorage, send: @escaping (ComposeDraft) async throws -> Void,
         accounts: [SendingAccount] = [], suggestContacts: @escaping ContactLookup = { _, _ in [] },
         signature: @escaping (String?) async -> String? = { _ in nil }) {
        _draft = State(initialValue: draft)
        _original = State(initialValue: draft)
        _session = State(initialValue: DraftSession(storage: drafts, existing: draft.gmailDraftID.flatMap { id in
            draft.accountID.map { DraftRef(accountID: $0, draftID: id) }
        }, draftID: draft.id, accountID: draft.accountID))
        self.recoversLocalDraft = drafts.isLocalRecovery(draft.id)
        _showsCc = State(initialValue: !draft.cc.isEmpty)
        _showsBcc = State(initialValue: !draft.bcc.isEmpty)
        self.send = send
        self.accounts = accounts
        self.suggestContacts = suggestContacts
        self.signature = signature
    }

    private var senderAddress: String {
        (accounts.first { $0.id == draft.accountID } ?? accounts.first)?.email ?? ""
    }

    /// A reply goes out from the account that received the mail, so only new messages can change it.
    private var choosesSender: Bool { accounts.count > 1 && draft.kind == .newMessage }

    /// Whether the person has changed anything since the composer opened.
    private var hasChanges: Bool { draft.hasContent && draft != original }

    private enum Field: Hashable {
        case recipient, cc, bcc, subject, body
    }

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            Divider()
            editor
            if !draft.attachments.isEmpty { attachmentStrip }
            DraftSaveStatus(session: session, draft: draft) { Task { await saveCurrentDraft() } }
            if sendError != nil { footer }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 440, idealHeight: 600)
        .navigationTitle(draft.subject.isEmpty ? draft.kind.title : draft.subject)
        .toolbar { windowToolbar }
        .disabled(isSending || isClosing)
        .task(id: editorReady && !isSending && !isClosing ? DraftSession.Snapshot(draft) : nil) {
            guard editorReady, !isSending, !isClosing,
                  hasChanges || recoversLocalDraft || session.hasStartedSaving, !session.isSaved(draft) else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await saveCurrentDraft()
        }
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return true
        } isTargeted: { isDropTarget = $0 }
        .fileImporter(isPresented: $choosesFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .background {
            Button("Close", action: requestClose)
                .keyboardShortcut(.cancelAction).hidden()
        }
        .background(WindowReader(closeGuard: closeGuard) { session.attach(to: $0) })
        // The red button and ⌘W ask the same question as Esc.
        .onAppear {
            closeGuard.shouldClose = {
                guard !isSending, !isClosing else { return false }
                guard hasChanges || recoversLocalDraft || session.hasStartedSaving else { return true }
                saveAndClose()
                return false
            }
        }
        .onDisappear { session.finish() }
        // Writing from another account means that account's signature.
        .onChange(of: draft.accountID) {
            Task { await addSignature() }
        }
        .onAppear {
            // The rich editor takes the cursor itself once it has loaded.
            if draft.recipient.isEmpty { focusedField = .recipient }
        }
        .alert("Discard this draft?", isPresented: $asksToKeep) {
            Button("Discard Draft", role: .destructive) {
                Task {
                    isClosing = true
                    await session.discard()
                    if case .failed(let message) = session.state { sendError = message; isClosing = false }
                    else { closeNow() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The draft will be deleted from this Mac and Gmail. This can’t be undone.")
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
            Button("Discard Draft", systemImage: "trash") { asksToKeep = true }
                .help("Discard Draft")
                .disabled(isSending || isClosing)
        }
        ToolbarItem(placement: .primaryAction) {
            SendButton(canSend: draft.canSend, isSending: isSending, action: sendMessage)
        }
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
            }
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var editor: some View {
        RichTextEditor(
            html: draft.html ?? "", controller: editorController, focusOnLoad: !draft.recipient.isEmpty,
            loaded: { content in
                // The editor tidies the markup it was given. That is not a change the person made.
                apply(content, to: &draft)
                apply(content, to: &original)
                // A draft that already exists has its signature, and what was saved is what is on screen.
                editorReady = true
                if draft.gmailDraftID == nil, !recoversLocalDraft {
                    Task { await addSignature() }
                } else if !recoversLocalDraft { session.markSaved(draft) }
            },
            changed: { apply($0, to: &draft) },
            dropFiles: attach
        )
    }

    /// Puts the account's Gmail signature in once the editor is ready. Adding it is not an edit the person made.
    private func addSignature() async {
        let request = UUID()
        let accountID = draft.accountID
        signatureRequestID = request
        let html = await signature(accountID)
        guard signatureRequestID == request, draft.accountID == accountID, !isSending, !isClosing else { return }
        if let update = await editorController.setSignature(html) {
            var before = original
            apply(update.before, to: &before)
            let wasUntouched = before == original
            apply(update.after, to: &draft)
            // Only the signature changes the baseline. Text entered while Gmail was loading remains an edit.
            if wasUntouched { apply(update.after, to: &original) }
        }
    }

    private func apply(_ content: EditorContent, to draft: inout ComposeDraft) {
        draft.html = content.html
        draft.body = content.text
        draft.ownText = content.ownText
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
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .onAppear { AccessibilityNotification.Announcement(sendError).post() }
            }
        }
    }

    // MARK: Actions

    private func attach(_ urls: [URL]) {
        for url in urls where !draft.attachments.contains(url) { draft.attachments.append(url) }
    }

    /// Closing keeps work as a draft; discarding is always explicit.
    private func requestClose() {
        if closeGuard.shouldClose() { closeNow() }
    }

    private func closeNow() {
        closeGuard.allowsClose = true
        dismiss()
    }

    private func saveCurrentDraft(allowClosing: Bool = false) async {
        guard !isSending, allowClosing || !isClosing, !Task.isCancelled else { return }
        let content = await editorController.content()
        guard !isSending, allowClosing || !isClosing, !Task.isCancelled else { return }
        if let content { apply(content, to: &draft) }
        await session.save(draft)
    }

    private func saveAndClose() {
        guard !isClosing else { return }
        isClosing = true
        Task {
            await saveCurrentDraft(allowClosing: true)
            if session.isSaved(draft) || session.isSavedLocally(draft) { closeNow() }
            else {
                if case .failed(let message) = session.state { sendError = message }
                isClosing = false
            }
        }
    }

    private func sendMessage() {
        Task {
            isSending = true
            sendError = nil
            do {
                // The editor reports changes after a short pause; send what is on screen, not what was last reported.
                if let content = await editorController.content() { apply(content, to: &draft) }
                // A message that is already a Gmail draft is sent as that draft, so no copy is left behind.
                draft.gmailDraftID = await session.draftIDForSending(from: draft.accountID)
                try await send(draft)
                await session.removeLocalRecovery(for: draft.id)
                session.finish()
                closeNow()
            } catch {
                session.resumeSaving()
                sendError = error.localizedDescription
            }
            isSending = false
        }
    }
}

/// Lets the window's close button ask first. Everything else the window's delegate does carries on as before.
@MainActor
private final class CloseGuard {
    var shouldClose: () -> Bool = { true }
    var allowsClose = false
}

nonisolated private final class CloseDelegate: NSObject, NSWindowDelegate {
    weak var inner: NSWindowDelegate?
    let closeGuard: CloseGuard

    init(inner: NSWindowDelegate?, closeGuard: CloseGuard) {
        self.inner = inner
        self.closeGuard = closeGuard
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { closeGuard.allowsClose || closeGuard.shouldClose() }
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { inner }
}

/// Hands over the window a view lives in, which SwiftUI does not otherwise expose.
private struct WindowReader: NSViewRepresentable {
    let closeGuard: CloseGuard
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(closeGuard: closeGuard, onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowView: NSView {
        let closeGuard: CloseGuard
        let onChange: (NSWindow?) -> Void
        private var delegate: CloseDelegate?

        init(closeGuard: CloseGuard, onChange: @escaping (NSWindow?) -> Void) {
            self.closeGuard = closeGuard
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let delegate = CloseDelegate(inner: window.delegate, closeGuard: closeGuard)
            self.delegate = delegate
            window.delegate = delegate
            DispatchQueue.main.async { [onChange] in onChange(window) }
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
    ComposerView(
        draft: ComposeDraft(), drafts: DraftStorage(save: { _, _ in DraftRef(accountID: "a", draftID: "d") }, delete: { _ in },
                                                    claim: { _, _ in }, release: { _ in }),
        send: { _ in }, accounts: [SendingAccount(id: "a", email: "alex@example.com")]
    )
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
