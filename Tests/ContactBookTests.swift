import Foundation
import Testing
@testable import Postie

@Suite("Contact suggestions")
struct ContactBookTests {
    private func source(from sender: String, name: String = "", to: String = "", cc: String = "", at days: Double = 0) -> ContactSource {
        ContactSource(senderName: name, senderEmail: sender, recipient: to, cc: cc, date: Date(timeIntervalSince1970: days * 86_400))
    }

    @Test("Parsing handles quoted commas, bare addresses and junk")
    func parsing() {
        let parsed = ContactBook.parse("\"Doe, Jo\" <jo@x.com>, bob@y.com, Undisclosed recipients:, <z@z.org>")
        #expect(parsed.map(\.email) == ["jo@x.com", "bob@y.com", "z@z.org"])
        #expect(parsed.map(\.name) == ["Doe, Jo", "", ""])
    }

    @Test("Matches names and addresses, never suggests the account itself")
    func matching() {
        let sources = [
            source(from: "sophie@example.com", name: "Sophie Chen", to: "Alex <alex@example.com>", cc: "james@example.com"),
            source(from: "alex@example.com", to: "Sophie Chen <sophie@example.com>, sam@example.com")
        ]
        let found = ContactBook.suggestions(from: sources, matching: "so", excluding: "alex@example.com")
        #expect(found.map(\.email) == ["sophie@example.com"])
        #expect(found.first?.name == "Sophie Chen")
        #expect(ContactBook.suggestions(from: sources, matching: "alex", excluding: "ALEX@example.com").isEmpty)
        #expect(ContactBook.suggestions(from: sources, matching: "chen", excluding: "alex@example.com").map(\.email) == ["sophie@example.com"])
    }

    @Test("People you write to rank above people who write to you, then by frequency")
    func ranking() {
        let sources = [
            source(from: "sam.sender@example.com", name: "Sam Sender", at: 5),
            source(from: "sam.sender@example.com", name: "Sam Sender", at: 6),
            source(from: "me@example.com", to: "sam.target@example.com", at: 1)
        ]
        let found = ContactBook.suggestions(from: sources, matching: "sam", excluding: "me@example.com")
        #expect(found.map(\.email) == ["sam.target@example.com", "sam.sender@example.com"])
    }

    @Test("Prefix matches beat substring matches")
    func prefixFirst() {
        let sources = [
            source(from: "me@example.com", to: "ann@example.com, joanna@example.com, joanna@example.com", at: 1)
        ]
        #expect(ContactBook.suggestions(from: sources, matching: "an", excluding: "me@example.com").map(\.email)
                == ["ann@example.com", "joanna@example.com"])
    }

    @Test("The address being typed is the text after the last comma")
    func tokens() {
        #expect(AddressToken.current(in: "a@b.com, so") == "so")
        #expect(AddressToken.current(in: "so") == "so")
        #expect(AddressToken.current(in: "a@b.com, ") == "")
        #expect(AddressToken.completing("a@b.com, so", with: "sophie@example.com") == "a@b.com, sophie@example.com")
    }

    @Test("The cache finds contacts in stored address headers")
    func cacheLookup() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "alex@example.com"))
        let conversation = try GmailFixtures.conversation("a1")
        _ = try await session.savePage(GmailPage(conversations: [conversation], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        let sources = try await session.contactSources(matching: "jam")
        #expect(ContactBook.suggestions(from: sources, matching: "jam", excluding: "alex@example.com").map(\.email) == ["james@example.com"])
        #expect(try await session.contactSources(matching: "100%").isEmpty)
    }
}

@Suite("Google contacts", .timeLimit(.minutes(1)))
struct GoogleContactsTests {
    private actor PeopleTransport: GmailTransport {
        private(set) var urls: [URL] = []
        func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
            let url = try #require(request.url)
            urls.append(url)
            let query = url.query ?? ""
            let json: String
            switch url.path {
            case "/v1/people/me/connections" where query.contains("pageToken=p2"):
                json = #"{"connections":[{"names":[{"displayName":"Dana Novak"}],"emailAddresses":[{"value":"dana@x.com"},{"value":"dana@home.org"}]}]}"#
            case "/v1/people/me/connections":
                json = #"{"connections":[{"names":[{"displayName":"Sophie Chen"}],"emailAddresses":[{"value":"sophie@example.com"}]},{"emailAddresses":[{"value":"nameless@x.com"}]},{"names":[{"displayName":"No Address"}]}],"nextPageToken":"p2"}"#
            case "/v1/otherContacts":
                json = #"{"otherContacts":[{"emailAddresses":[{"value":"seen@x.com"}]}]}"#
            default:
                return GmailHTTPResponse(data: Data(), statusCode: 404)
            }
            return GmailHTTPResponse(data: Data(json.utf8), statusCode: 200)
        }
    }

    @Test("Saved and collected contacts are read across pages, from the People API")
    func reads() async throws {
        let transport = PeopleTransport()
        let contacts = try await GmailAPI(transport: transport) { "t" }.contacts()
        #expect(contacts == [
            DirectoryContact(name: "Sophie Chen", email: "sophie@example.com", isSaved: true),
            DirectoryContact(name: "", email: "nameless@x.com", isSaved: true),
            DirectoryContact(name: "Dana Novak", email: "dana@x.com", isSaved: true),
            DirectoryContact(name: "Dana Novak", email: "dana@home.org", isSaved: true),
            DirectoryContact(name: "", email: "seen@x.com", isSaved: false)
        ])
        let urls = await transport.urls
        #expect(urls.allSatisfy { $0.host == "people.googleapis.com" })
        #expect(urls.first?.query?.contains("personFields=names,emailAddresses") == true)
    }

    @Test("Contacts are kept per account, found by name or address, and a saved one wins over a collected duplicate")
    func cache() async throws {
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        try await session.saveContacts([
            DirectoryContact(name: "", email: "Sophie@Example.com", isSaved: false),
            DirectoryContact(name: "Sophie Chen", email: "sophie@example.com", isSaved: true),
            DirectoryContact(name: "Bob", email: "bob@x.com", isSaved: false)
        ])
        let found = try await session.contacts(matching: "soph")
        #expect(found == [DirectoryContact(name: "Sophie Chen", email: "sophie@example.com", isSaved: true)])
        #expect(try await session.contacts(matching: "x.com").map(\.email) == ["bob@x.com"])
        #expect(try await session.contacts(matching: "100%").isEmpty)
        try await session.saveContacts([])
        #expect(try await session.contacts(matching: "soph").isEmpty)
    }

    @Test("A saved contact beats people from mail, keeps its own name and counts for more than a collected one")
    func ranking() {
        let mail = [ContactSource(senderName: "Sam S.", senderEmail: "sam@x.com", recipient: "", cc: "", date: Date(timeIntervalSince1970: 100))]
        let directory = [
            DirectoryContact(name: "Samantha Stone", email: "sam@x.com", isSaved: true),
            DirectoryContact(name: "Sam Collected", email: "samuel@x.com", isSaved: false)
        ]
        let found = ContactBook.suggestions(from: mail, directory: directory, matching: "sam", excluding: "me@x.com")
        #expect(found.map(\.email) == ["sam@x.com", "samuel@x.com"])
        #expect(found.first?.name == "Samantha Stone")
        // Without mail, contacts alone are offered.
        #expect(ContactBook.suggestions(from: [], directory: directory, matching: "stone", excluding: "me@x.com").map(\.email) == ["sam@x.com"])
    }
}
