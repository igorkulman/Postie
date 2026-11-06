import Foundation
import Testing
@testable import Postie

@Suite("Gmail message parsing")
struct GmailModelsTests {
    @Test("Gmail IDs and internal dates preserve conversation ordering")
    func identityAndOrdering() throws {
        let conversation = try GmailFixtures.conversation("a1")
        #expect(conversation.id == "a1")
        #expect(conversation.messages.map(\.id) == ["b1", "b2"])
        #expect(conversation.latestDate == Date(timeIntervalSince1970: 2000))
    }

    @Test("Encoded headers and case-insensitive field names are decoded")
    func headers() throws {
        let conversation = try GmailFixtures.conversation("a1")
        let latest = try #require(conversation.messages.last)
        #expect(conversation.subject == "Coffee plans")
        #expect(latest.senderName == "Sophie Chen")
        #expect(latest.senderEmail == "sophie@example.com")
        #expect(latest.cc == "james@example.com")
    }

    @Test("Reply-To is decoded and survives the cache")
    func replyTo() async throws {
        let json = #"{"id":"t1","messages":[{"id":"m1","internalDate":"1000","labelIds":["INBOX"],"payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"News <news@example.com>"},{"name":"reply-to","value":"=?UTF-8?B?U3VwcG9ydCDinIU=?= <help@example.com>"},{"name":"Subject","value":"Hi"}],"body":{"data":"SGk"}}},{"id":"m2","internalDate":"2000","labelIds":["INBOX"],"payload":{"mimeType":"text/plain","headers":[{"name":"From","value":"b@example.com"}],"body":{"data":"SGk"}}}]}"#
        let resource = try JSONDecoder().decode(GmailThreadResource.self, from: Data(json.utf8))
        let conversation = try resource.conversation(includeBody: true)
        #expect(conversation.messages[0].replyTo == "Support \u{2705} <help@example.com>")
        #expect(conversation.messages[1].replyTo.isEmpty)
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        try await session.saveConversation(conversation)
        #expect(try await session.conversation(id: "t1")?.messages.map(\.replyTo) == [conversation.messages[0].replyTo, ""])
    }

    @Test("System and custom labels coexist")
    func labels() throws {
        let conversation = try GmailFixtures.conversation("a1")
        #expect(conversation.labelIDs == Set(["INBOX", "UNREAD", "SENT", "STARRED", "Label_42"]))
        #expect(conversation.isUnread)
        #expect(conversation.isStarred)
    }

    @Test("Metadata does not extract bodies")
    func metadata() throws {
        let metadata = try GmailFixtures.conversation("a1", includeBody: false)
        #expect(metadata.messages.allSatisfy { $0.body.isEmpty && $0.htmlBody == nil && !$0.bodyLoaded })
    }

    @Test("Nested plain text is preferred and attachments are excluded")
    func plainText() throws {
        let conversation = try GmailFixtures.conversation("a1")
        #expect(conversation.messages.last?.body == "Hello Alex,\n\nCoffee tomorrow?")
        #expect(conversation.messages.last?.snippet == "Coffee & plans")
        #expect(conversation.messages.last?.htmlBody?.contains("<p>Hello &amp; goodbye") == true)
        #expect(conversation.messages.first?.htmlBody == nil)
        #expect(conversation.messages.last?.htmlBody?.contains("Do not show this attachment") == false)
    }

    @Test("Loaded headers, snippets and bodies are searchable")
    func search() throws {
        let conversation = try GmailFixtures.conversation("a1")
        #expect(conversation.matches(" SOPHIE "))
        #expect(conversation.matches("james@example.com"))
        #expect(conversation.matches("tomorrow"))
        #expect(!conversation.matches("missing phrase"))
        #expect(!conversation.matches("tracking.example.com"))
        #expect(!conversation.matches("display:none"))
    }

    @Test("HTML-only mail retains markup alongside a non-rendering text fallback")
    func htmlFallback() throws {
        let resource = try JSONDecoder().decode(GmailThreadResource.self, from: GmailFixtures.thread(htmlOnly: true))
        let conversation = try resource.conversation(includeBody: true)
        #expect(conversation.messages.last?.body == "Hello & goodbye 👋")
        #expect(conversation.messages.last?.htmlBody?.contains("<style>") == true)
        #expect(conversation.messages.last?.htmlBody?.contains("<script>") == true)
        #expect(conversation.matches("goodbye"))
    }

    @Test("HTML attachments and forwarded messages are excluded")
    func htmlAttachments() throws {
        let object: [String: Any] = ["mimeType": "multipart/mixed", "parts": [
            ["mimeType": "text/html", "filename": "attached.html", "body": ["data": Data("<b>Attachment</b>".utf8).base64EncodedString()]],
            ["mimeType": "text/html", "headers": [["name": "Content-Disposition", "value": "attachment"]],
             "body": ["data": Data("<b>Also attached</b>".utf8).base64EncodedString()]],
            ["mimeType": "message/rfc822", "parts": [
                ["mimeType": "text/html", "body": ["data": Data("<b>Forwarded attachment</b>".utf8).base64EncodedString()]]
            ]],
            ["mimeType": "text/html", "body": ["data": Data("<p>Message</p>".utf8).base64EncodedString()]]
        ]]
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try GmailText.content(part) == GmailText.Content(plainText: "Message", html: "<p>Message</p>"))
    }

    @Test("HTML MIME charsets are decoded without changing the markup")
    func htmlCharset() throws {
        let html = "<p>Café</p>"
        let object: [String: Any] = ["mimeType": "text/html",
            "headers": [["name": "Content-Type", "value": "text/html; charset=windows-1252"]],
            "body": ["data": try #require(html.data(using: .windowsCP1252)).base64EncodedString()]]
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try GmailText.content(part) == GmailText.Content(plainText: "Café", html: html))
    }

    @Test("Text in a single-byte charset still decodes", arguments: [
        ("iso-8859-1", String.Encoding.isoLatin1), ("latin1", .isoLatin1), ("windows-1252", .windowsCP1252)
    ])
    func singleByteCharset(charset: String, encoding: String.Encoding) throws {
        let data = try #require("Buenos días Jesús".data(using: encoding))
        #expect(GmailText.decode(data, charset: charset) == "Buenos días Jesús")
    }

    @Test("UTF-8 text declaring a single-byte charset keeps its accents",
          arguments: ["iso-8859-1", "ISO-8859-1", "latin1", "windows-1252", "us-ascii"])
    func mislabeledUTF8(charset: String) throws {
        let text = "Buenos días Jesús, ¿cómo estás? “Añó” €5"
        let object: [String: Any] = ["mimeType": "text/plain",
            "headers": [["name": "Content-Type", "value": "text/plain; charset=\(charset)"]],
            "body": ["data": Data(text.utf8).base64EncodedString()]]
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try GmailText.body(part) == text)
    }

    @Test("Misdecoded UTF-8 is repaired and everything else is left alone")
    func repairingMisdecodedUTF8() throws {
        let text = "Buenos días Jesús,\r\n¿Cómo estás? Ángel “Añó” €5"
        for encoding in [String.Encoding.isoLatin1, .windowsCP1252] {
            // A byte windows-1252 leaves undefined cannot have come through that charset.
            guard let garbled = String(data: Data(text.utf8), encoding: encoding) else { continue }
            #expect(garbled != text)
            #expect(GmailText.repairingMisdecodedUTF8(garbled) == text)
        }
        let correct = ["Buenos días Jesús", "Plain ASCII\r\nonly", "Ünïcödé", "日本語 and días", "Ángel, 5° Ñandú", ""]
        for value in correct {
            #expect(GmailText.repairingMisdecodedUTF8(value) == value)
        }
    }

    @Test("Message previews run on past line breaks up to the room they are given")
    @MainActor
    func messagePreview() {
        func message(_ body: String) -> MailMessage {
            MailMessage(id: "m", senderName: "A", senderEmail: "a@example.com", recipient: "b@example.com", date: .distantPast, body: body)
        }
        #expect(message("Buenos días,\r\n\r\nComo estás?\n\tBien  ").preview == "Buenos días, Como estás? Bien")
        let long = String(repeating: "palabra ", count: 50).trimmingCharacters(in: .whitespaces)
        #expect(message(long).preview == long)
        #expect(message(String(repeating: "x", count: 100_000)).preview.count == 1000)
        let thread = MailThread(id: "t", subject: "s", messages: [message("old"), message("New\r\nline")], mailbox: .inbox)
        #expect(thread.preview == "New line")
    }

    @Test("Malformed optional HTML falls back to valid plain text")
    func malformedHTMLAlternative() throws {
        let json = #"{"mimeType":"multipart/alternative","parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8="}},{"mimeType":"text/html","body":{"data":"%%%"}}]}"#
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: Data(json.utf8))
        #expect(try GmailText.content(part) == GmailText.Content(plainText: "Hello", html: nil))
    }

    @Test("The reader projection retains HTML only for full conversations")
    @MainActor
    func htmlProjection() throws {
        let conversation = try GmailFixtures.conversation("a1")
        #expect(conversation.presentation(includingBodies: true).messages.last?.htmlBody == conversation.messages.last?.htmlBody)
        #expect(conversation.presentation(includingBodies: false).messages.allSatisfy { $0.htmlBody == nil })
    }

    @Test("URL-safe base64 accepts unpadded input and rejects malformed input")
    func base64() {
        #expect(GmailText.base64URL("_w") == Data([255]))
        #expect(GmailText.base64URL("%%%") == nil)
    }

    @Test("Adjacent encoded words and bare sender addresses are supported")
    func headerText() {
        #expect(GmailText.decodeHeader("=?UTF-8?Q?Hello?= =?UTF-8?Q?_Alex?=") == "Hello Alex")
        #expect(GmailText.sender("friend@example.com").name == "friend@example.com")
        #expect(GmailText.decodeEntities("&#65; &#x1f44b;") == "A 👋")
    }

    @Test("Malformed MIME data surfaces a parsing error")
    func malformedBody() throws {
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: Data(#"{"mimeType":"text/plain","body":{"data":"%%%"}}"#.utf8))
        #expect(throws: GmailError.invalidResponse) { try GmailText.body(part) }
    }

    @Test("Bodies requiring attachment downloads are explained")
    func externalBody() throws {
        let part = try JSONDecoder().decode(GmailThreadResource.Part.self, from: Data(#"{"mimeType":"text/plain","body":{"attachmentId":"external"}}"#.utf8))
        let text = try GmailText.body(part)
        #expect(text.contains("attachment download"))
    }
}
