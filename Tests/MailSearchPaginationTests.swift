import Testing
@testable import Postie

@Suite("Mail search pagination")
@MainActor
struct MailSearchPaginationTests {
    @Test("All Mail search from Outbox retains loading status and continuation pages")
    func searchFromOutbox() async throws {
        let api = ControlledSearchAPI()
        let hub = await MailHubTests().makeHub(["a": api])
        hub.changeMailbox(.outbox)
        hub.setSearch("Subject", scope: .allMail)
        let first = Task { await hub.performSearch() }
        try await api.waitForSearch()
        #expect(hub.isLoadingMailbox)
        api.finishSearch(GmailPage(conversations: [MailHubTests.conversation("first", at: 200)], nextPageToken: "next"))
        await first.value
        #expect(hub.hasMorePages)
        let second = Task { await hub.loadMore() }
        try await api.waitForSearch()
        #expect(api.pageTokens == [nil, "next"])
        api.finishSearch(GmailPage(conversations: [MailHubTests.conversation("second", at: 100)], nextPageToken: nil))
        await second.value
        #expect(hub.conversationKeys.map(\.threadID) == ["first", "second"])
        #expect(!hub.hasMorePages)
    }
}
