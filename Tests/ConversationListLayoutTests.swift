import AppKit
import SwiftUI
import Testing
@testable import Postie

@Suite("Native conversation list layout", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ConversationListLayoutTests {
    @Test("An inserted notification retains its full row height before and after opening")
    func insertedNotification() async throws {
        let mail = SelectionRegressionMail()
        let hub = try await mail.makeHub()
        let suiteName = "ConversationListLayoutTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let host = NSHostingView(rootView: GmailInboxView(hub: hub).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(in: host, rows: 2))
        try await waitForLayout(host: host) { !hub.showingCachedMail && !hub.isLoadingMailbox }
        #expect(table.numberOfRows == 2)

        let notification = GmailConversation(
            id: "notification", subject: "Re: tw-ios | [TW-17440]: Show a tutorial when opening the Track Board (!3318)",
            messages: (0..<16).map { index in
                GmailMessage(id: "notification-\(index)", senderName: "Olivier Morandi (@olivier)",
                             senderEmail: "gitlab@example.com", recipient: SampleAccount.email, cc: "",
                             date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                             snippet: "Olivier Morandi commented on a discussion. Yes, the permission works as a feature flag.",
                             body: "A notification from a long discussion.", labelIDs: ["INBOX", "UNREAD"])
            }
        )
        mail.insertConversation(notification)
        await hub.refresh()
        host.layoutSubtreeIfNeeded()
        try await waitForInsertionLayout(table: table, host: host)
        #expect(table.numberOfRows == 3)
        await finishRowLayout(host: host)
        try assertNotificationHeight(table: table, notification: notification)

        let key = ConversationKey(accountID: SelectionRegressionMail.accountID, threadID: notification.id)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if let outline = table as? NSOutlineView {
            outline.delegate?.outlineViewSelectionDidChange?(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        }
        try await waitForLayout(host: host) { hub.openConversation(for: key)?.messages.count == 16 }
        await finishRowLayout(host: host)
        try assertNotificationHeight(table: table, notification: notification)
        await hub.setUnread(key, false)
        await finishRowLayout(host: host)
        try assertNotificationHeight(table: table, notification: notification)

        // Changing the saved list preference must resize existing native rows, not just new ones.
        let defaultHeight = table.rect(ofRow: 0).height
        preferences.set(26, forKey: SettingsKey.conversationListTextSize)
        try await waitForLayout(host: host) { table.rect(ofRow: 0).height > defaultHeight }
        await finishRowLayout(host: host)
        try assertNotificationHeight(table: table, notification: notification, textSize: 26)
        let enlargedHeight = table.rect(ofRow: 0).height
        preferences.set(13, forKey: SettingsKey.conversationListTextSize)
        try await waitForLayout(host: host) { table.rect(ofRow: 0).height < enlargedHeight }
        await finishRowLayout(host: host)
        try assertNotificationHeight(table: table, notification: notification)
    }

    private func finishRowLayout(host: NSView) async {
        host.layoutSubtreeIfNeeded()
        // Drain the row-sizing work queued by AppKit's completed cell layout, not a timed sleep.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        host.layoutSubtreeIfNeeded()
    }

    private func waitForInsertionLayout(table: NSTableView, host: NSView) async throws {
        try await waitForLayout(host: host) {
            table.numberOfRows == 3 && table.rowView(atRow: 0, makeIfNecessary: true)?.superview === table
        }
    }

    private func waitForLayout(host: NSView, until ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            await Task.yield()
        }
        throw LayoutFailure.insertionDidNotFinish
    }

    private enum LayoutFailure: Error { case insertionDidNotFinish }

    private func assertNotificationHeight(table: NSTableView, notification: GmailConversation,
                                          textSize: Int = 13) throws {
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let renderer = ImageRenderer(content: MailThreadRow(thread: notification.presentation(includingBodies: false),
                                                          textSize: textSize))
        renderer.proposedSize = ProposedViewSize(width: cell.bounds.width, height: nil)
        let natural = try #require(renderer.nsImage)
        let row = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        #expect(table.rect(ofRow: 0).height >= natural.size.height)
        #expect(row.bounds.height >= natural.size.height)
        #expect(cell.bounds.height >= natural.size.height)
        #expect(row.visibleRect.height >= natural.size.height)
    }

    private func findTable(in view: NSView, rows: Int) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfRows == rows { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0, rows: rows) }.first
    }
}
