import SwiftUI

/// What the active window can do right now. A nil action disables its menu item.
struct MailActions {
    var currentMailbox: Mailbox
    var selectMailbox: (Mailbox) -> Void
    var newMessage: (() -> Void)?
    var refresh: (() -> Void)?
    var archive: (() -> Void)?
    var trash: (() -> Void)?
    var reply: (() -> Void)?
    var replyAll: (() -> Void)?
    var forward: (() -> Void)?
    var toggleRead: (() -> Void)?
    var toggleFlag: (() -> Void)?
    var selectionIsUnread = false
    var selectionIsFlagged = false
}

extension FocusedValues {
    @Entry var mailActions: MailActions?
}

struct MailCommands: Commands {
    @FocusedValue(\.mailActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { actions?.newMessage?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newMessage == nil)
        }

        CommandMenu("Mailbox") {
            Button("Get New Mail") { actions?.refresh?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.refresh == nil)
            Divider()
            ForEach(Array(Mailbox.allCases.enumerated()), id: \.element) { index, mailbox in
                Toggle(isOn: Binding(
                    get: { actions?.currentMailbox == mailbox },
                    set: { _ in actions?.selectMailbox(mailbox) }
                )) {
                    Label(mailbox.title, systemImage: mailbox.symbol)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .disabled(actions == nil)
            }
        }

        CommandMenu("Message") {
            Button("Reply") { actions?.reply?() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.reply == nil)
            Button("Reply All") { actions?.replyAll?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.replyAll == nil)
            Button("Forward") { actions?.forward?() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions?.forward == nil)
            Divider()
            Button(actions?.selectionIsUnread == true ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")) { actions?.toggleRead?() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.toggleRead == nil)
            Button(actions?.selectionIsFlagged == true ? String(localized: "Unflag") : String(localized: "Flag")) { actions?.toggleFlag?() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(actions?.toggleFlag == nil)
            Divider()
            Button("Archive") { actions?.archive?() }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(actions?.archive == nil)
            Button("Move to Trash") { actions?.trash?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.trash == nil)
        }
    }
}

/// Shared toolbar content so the demo and Gmail views stay identical.
struct MailToolbar: ToolbarContent {
    let actions: MailActions

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { actions.newMessage?() } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .disabled(actions.newMessage == nil)
            .help("New Message (⌘N)")
        }
        ToolbarItem(placement: .navigation) {
            Button { actions.refresh?() } label: {
                Label("Get New Mail", systemImage: "arrow.clockwise")
            }
            .disabled(actions.refresh == nil)
            .help("Get New Mail (⇧⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { actions.archive?() } label: { Label("Archive", systemImage: "archivebox") }
                .disabled(actions.archive == nil)
                .help("Archive (⌃⌘A)")
            Button { actions.trash?() } label: { Label("Move to Trash", systemImage: "trash") }
                .disabled(actions.trash == nil)
                .help("Move to Trash (⌘⌫)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { actions.reply?() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .disabled(actions.reply == nil)
                .help("Reply (⌘R)")
            Button { actions.replyAll?() } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .disabled(actions.replyAll == nil)
                .help("Reply All (⇧⌘R)")
            Button { actions.forward?() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .disabled(actions.forward == nil)
                .help("Forward (⇧⌘F)")
        }
    }
}
