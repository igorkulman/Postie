import AppKit

@MainActor
enum DockBadge {
    static func label(forUnreadCount count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return String(count)
    }

    static func update(unreadCount: Int?) {
        NSApplication.shared.dockTile.badgeLabel = label(forUnreadCount: unreadCount)
    }
}
