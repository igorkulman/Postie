import Testing
@testable import Postie

@Suite("Dock unread badge")
@MainActor
struct DockBadgeTests {
    @Test("Positive unread counts use the full number", arguments: [1, 25, 1234, 100_000])
    func positiveCounts(count: Int) {
        #expect(DockBadge.label(forUnreadCount: count) == String(count))
    }

    @Test("Zero, unknown and invalid counts remove the badge", arguments: [Int?.none, 0, -1])
    func noBadge(count: Int?) {
        #expect(DockBadge.label(forUnreadCount: count) == nil)
    }
}
