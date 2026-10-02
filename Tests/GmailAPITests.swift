import Foundation
import Testing
@testable import Postie

@Suite("Gmail REST client", .timeLimit(.minutes(1)))
struct GmailAPITests {
    @Test("Inbox metadata deduplicates IDs and tolerates deleted conversations")
    func metadata() async throws {
        let api = GmailAPI(transport: FixtureTransport()) { "fixture-token" }
        let page = try await api.mailbox(.inbox, pageToken: nil)
        #expect(page.conversations.map(\.id) == ["a1"])
        #expect(page.nextPageToken == "next +/=")
        #expect(page.conversations.first?.messages.last?.snippet == "List & snippet")
        #expect(page.conversations.allSatisfy { $0.messages.allSatisfy { $0.body.isEmpty } })
    }

    @Test("All requests are GETs to Gmail with credentials confined to headers")
    @MainActor
    func readOnlyAuthorization() async throws {
        let transport = FixtureTransport()
        var tokenCalls = 0
        let api = GmailAPI(transport: transport) { tokenCalls += 1; return "fixture-token" }
        for mailbox in Mailbox.allCases { _ = try await api.mailbox(mailbox, pageToken: nil) }
        _ = try await api.conversation(id: "a1")
        let requests = await transport.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.url?.host == "gmail.googleapis.com" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        #expect(requests.allSatisfy { $0.url?.absoluteString.contains("fixture-token") == false })
        #expect(tokenCalls == requests.count)
    }

    @Test("Inbox uses bounded pages and opaque pagination tokens are escaped")
    func paginationQueries() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        let page = try await api.mailbox(.inbox, pageToken: nil)
        _ = try await api.mailbox(.inbox, pageToken: page.nextPageToken)
        let requests = await transport.requests.filter { $0.url?.path.hasSuffix("/threads") == true }
        try #require(requests.count == 2)
        let url = try #require(requests[0].url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "labelIds", value: "INBOX")))
        #expect(query.contains(URLQueryItem(name: "maxResults", value: "25")))
        #expect(requests[1].url?.absoluteString.contains("%2B") == true)
        let nextURL = try #require(requests[1].url)
        let nextQuery = try #require(URLComponents(url: nextURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(nextQuery.contains(URLQueryItem(name: "pageToken", value: "next +/=")))
    }

    @Test("System folders use Gmail labels, with Spam and Trash explicitly included", arguments: [
        (Mailbox.inbox, "INBOX"), (.drafts, "DRAFT"), (.sent, "SENT"), (.junk, "SPAM"), (.trash, "TRASH")
    ])
    func folderQueries(input: (Mailbox, String)) async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        _ = try await api.mailbox(input.0, pageToken: "folder + token")
        let requests = await transport.requests
        let url = try #require(requests.first?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "labelIds", value: input.1)))
        #expect(query.contains(URLQueryItem(name: "maxResults", value: "25")))
        #expect(query.contains(URLQueryItem(name: "pageToken", value: "folder + token")))
        #expect(query.contains(URLQueryItem(name: "includeSpamTrash", value: "true")) == (input.0 == .junk || input.0 == .trash))
        #expect(!query.contains { $0.name == "q" })
    }

    @Test("Archive uses a search query, not a nonexistent Gmail label")
    func archiveQuery() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        _ = try await api.mailbox(.archive, pageToken: nil)
        let requests = await transport.requests
        let url = try #require(requests.first?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "q", value: "-in:inbox -in:sent -in:drafts -in:spam -in:trash")))
        #expect(!query.contains { $0.name == "labelIds" || $0.name == "includeSpamTrash" })
    }

    @Test("Archive excludes conversations still in another received-mail folder", arguments: [
        (["UNREAD", "Label_42"], true), (["INBOX"], false), (["DRAFT"], false),
        (["SPAM"], false), (["TRASH"], false)
    ])
    func archiveMembership(input: ([String], Bool)) async throws {
        let api = GmailAPI(transport: ArchiveFixtureTransport(labels: input.0)) { "fixture-token" }
        let page = try await api.mailbox(.archive, pageToken: nil)
        #expect(!page.conversations.isEmpty == input.1)
    }

    @Test("Outbox is local and makes no Gmail or token requests")
    @MainActor
    func localOutbox() async throws {
        let transport = FixtureTransport()
        var tokenCalls = 0
        let api = GmailAPI(transport: transport) { tokenCalls += 1; return "fixture-token" }
        let page = try await api.mailbox(.outbox, pageToken: nil)
        #expect(page.conversations.isEmpty)
        #expect(page.nextPageToken == nil)
        #expect(tokenCalls == 0)
        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test("Full bodies are only fetched when requesting a conversation")
    func bodyFetching() async throws {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        _ = try await api.mailbox(.inbox, pageToken: nil)
        let conversation = try await api.conversation(id: "a1")
        #expect(conversation.messages.last?.body == "Hello Alex,\n\nCoffee tomorrow?")
        let requests = await transport.requests
        let formats = requests.compactMap {
            $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value }
        }
        // The list asks for the full format only to see attachments, and without any body data.
        let listRequest = try #require(requests.first { $0.url?.path.contains("/threads/a1") == true })
        let listQuery = URLComponents(url: try #require(listRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(listQuery.contains { $0.name == "fields" })
        #expect(formats.last == "full")
        #expect(requests.last?.url?.query?.contains("fields") == false)
    }

    @Test("Malformed responses and expired sessions are surfaced", arguments: [FixtureTransport.Mode.invalid, .denied])
    func responseErrors(mode: FixtureTransport.Mode) async {
        let api = GmailAPI(transport: FixtureTransport(mode: mode)) { "fixture-token" }
        let expected: GmailError = mode == .invalid ? .invalidResponse : .http(401)
        await #expect(throws: expected) { try await api.mailbox(.inbox, pageToken: nil) }
    }

    @Test("An empty Inbox can omit its threads field")
    func emptyInbox() async throws {
        let api = GmailAPI(transport: FixtureTransport(mode: .empty)) { "fixture-token" }
        let page = try await api.mailbox(.inbox, pageToken: nil)
        #expect(page.conversations.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    @Test("Unsafe IDs are rejected before making any request")
    func resourcePaths() async {
        let transport = FixtureTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        await #expect(throws: GmailError.invalidResponse) { try await api.conversation(id: "../profile") }
        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test("Metadata fan-out is limited to six concurrent requests")
    func concurrencyBound() async throws {
        let transport = ConcurrencyTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        let task = Task { try await api.mailbox(.inbox, pageToken: nil) }
        do {
            try await transport.waitForSix()
            await transport.release()
            let page = try await task.value
            let maximum = await transport.maximum
            #expect(maximum == 6)
            #expect(page.conversations.count == 9)
        } catch {
            task.cancel()
            await transport.release()
            _ = await task.result
            throw error
        }
    }
}
