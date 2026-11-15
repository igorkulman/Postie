import SwiftUI

struct BulkConversationContextMenu: View {
    let model: InboxModel
    let keys: Set<ConversationKey>

    private var hub: MailHub { model.hub }

    var body: some View {
        if keys.allSatisfy({ hub.canModifyLabels($0) && !model.isRemoving($0) }) {
            Button("Mark as Read", systemImage: "envelope.open") { model.markRead(keys, unread: false) }
            Button("Mark as Unread", systemImage: "envelope.badge") { model.markRead(keys, unread: true) }
            Divider()
        }
        if keys.allSatisfy({ hub.canArchive($0) && !model.isRemoving($0) }) {
            Button("Archive", systemImage: "archivebox") { model.remove(keys, archiving: true) }
        }
        if keys.allSatisfy({ hub.canTrash($0) && !model.isRemoving($0) }) {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { model.remove(keys, archiving: false) }
        }
        if keys.allSatisfy({ hub.canActOnOutboxItem($0) }) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                for key in keys { model.deleteOutboxItem(key) }
            }
        }
    }
}
