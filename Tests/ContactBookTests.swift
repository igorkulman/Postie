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
