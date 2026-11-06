import Foundation
import Testing
@testable import Postie

@Suite("Attachments")
struct AttachmentTests {
    private func part(_ id: String, _ type: String, filename: String = "", attachment: String? = nil, size: Int = 10,
                      headers: [(String, String)] = [], parts: [String] = []) -> String {
        let headerJSON = headers.map { #"{"name":"\#($0.0)","value":"\#($0.1)"}"# }.joined(separator: ",")
        let body = attachment.map { #"{"attachmentId":"\#($0)","size":\#(size)}"# } ?? #"{"size":0}"#
        return #"{"partId":"\#(id)","mimeType":"\#(type)","filename":"\#(filename)","headers":[\#(headerJSON)],"body":\#(body),"parts":[\#(parts.joined(separator: ","))]}"#
    }

    private func resource(_ payload: String) throws -> GmailThreadResource {
        let json = #"{"id":"t","messages":[{"id":"m","internalDate":"1000","payload":\#(payload)}]}"#
        return try JSONDecoder().decode(GmailThreadResource.self, from: Data(json.utf8))
    }

    @Test("Files are listed in order, embedded images are not")
    func listing() throws {
        let payload = part("", "multipart/mixed", parts: [
            part("0", "text/plain"),
            part("1", "application/pdf", filename: "invoice.pdf", attachment: "A1", size: 2048,
                 headers: [("Content-Disposition", "attachment; filename=invoice.pdf"), ("Content-ID", "<f_1>")]),
            part("2", "image/png", filename: "logo.png", attachment: "A2", headers: [("Content-ID", "<logo>"), ("Content-Disposition", "inline")]),
            part("3", "multipart/related", parts: [
                part("3.0", "image/jpeg", filename: "photo.jpg", attachment: "A3", headers: [("Content-ID", "<photo>")]),
                part("3.1", "application/zip", filename: "archive.zip", attachment: "A4")
            ])
        ])
        let conversation = try resource(payload).conversation(includeBody: false)
        let attachments = try #require(conversation.messages.first?.attachments)
        #expect(attachments.map(\.filename) == ["invoice.pdf", "archive.zip"])
        #expect(attachments.first == MailAttachment(messageID: "m", partID: "1", attachmentID: "A1", filename: "invoice.pdf",
                                                    mimeType: "application/pdf", size: 2048))
    }

    @Test("A named part without downloadable data is not an attachment")
    func withoutData() throws {
        let conversation = try resource(part("1", "application/pdf", filename: "empty.pdf")).conversation(includeBody: false)
        #expect(conversation.messages.first?.attachments.isEmpty == true)
    }

    @Test("Attachments survive the cache")
    func cache() async throws {
        let attachment = MailAttachment(messageID: "m", partID: "1", attachmentID: "A1", filename: "a.pdf", mimeType: "application/pdf", size: 5)
        let conversation = GmailConversation(id: "t", subject: "S", messages: [
            GmailMessage(id: "m", senderName: "N", senderEmail: "n@example.com", recipient: "r@example.com", cc: "",
                         date: Date(timeIntervalSince1970: 1), snippet: "s", body: "", bodyLoaded: false,
                         attachments: [attachment], labelIDs: ["INBOX"])
        ])
        let cache = try await GmailCache.inMemory()
        let session = try await cache.session(for: CachedGmailAccount(id: "a", email: "a@example.com"))
        _ = try await session.savePage(GmailPage(conversations: [conversation], nextPageToken: nil), mailbox: .inbox, refreshing: true)
        #expect(try await session.conversation(id: "t")?.messages.first?.attachments == [attachment])
    }

    @Test("An embedded image is found by its Content-ID, however it is marked")
    func embeddedImageLookup() throws {
        let payload = part("", "multipart/mixed", parts: [
            part("0", "multipart/related", parts: [
                part("0.1", "image/png", filename: "logo.png", attachment: "A1", headers: [("Content-ID", "<logo@example>")])
            ]),
            part("1", "image/jpeg", filename: "photo.jpg", attachment: "A2",
                 headers: [("Content-Disposition", "attachment; filename=photo.jpg"), ("Content-ID", "<photo>")]),
            part("2", "image/gif", attachment: "A3", headers: [("Content-ID", "bare")]),
            part("3", "text/html", filename: "page.html", attachment: "A4", headers: [("Content-ID", "<page>")]),
            part("4", "image/png", filename: "empty.png", headers: [("Content-ID", "<empty>")])
        ])
        let message = try #require(try resource(payload).messages?.first?.payload)
        func found(_ id: String) -> String? { message.embeddedImage(contentID: id, messageID: "m")?.attachmentID }
        #expect(found("logo@example") == "A1")
        #expect(found("photo") == "A2")
        #expect(found("bare") == "A3")
        #expect(found("page") == nil, "Only images are served to the page")
        #expect(found("empty") == nil)
        #expect(found("missing") == nil)
    }

    @Test("A cid: URL gives the Content-ID it was encoded from", arguments: [
        ("cid:logo@example", "logo@example"),
        ("cid:image001.png%4001D9AB12", "image001.png@01D9AB12"),
        ("CID:Mixed.Case", "Mixed.Case"),
        ("https://example.com/logo", nil),
        ("cid:", nil)
    ] as [(String, String?)])
    func contentIDFromURL(input: (String, String?)) throws {
        #expect(EmbeddedImageHandler.contentID(of: try #require(URL(string: input.0))) == input.1)
    }

    @Test("A Content-ID cannot choose where its image is saved, and two never share a file")
    func embeddedImageFiles() {
        func url(_ contentID: String) -> URL {
            AttachmentFiles.embeddedImageURL(contentID: contentID, messageID: "m", accountID: "a")
        }
        let hostile = url("../../../../etc/passwd")
        #expect(hostile.deletingLastPathComponent() == url("logo").deletingLastPathComponent())
        #expect(hostile.lastPathComponent.allSatisfy { $0.isHexDigit })
        #expect(url("a@b") != url("a_b"))
        #expect(url("logo") == url("logo"))
    }

    private actor EmbeddedTransport: GmailTransport {
        var requests: [URLRequest] = []
        func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
            requests.append(request)
            if request.url?.path.hasSuffix("/attachments/FRESH") == true {
                return GmailHTTPResponse(data: Data(#"{"data":"aGVsbG8"}"#.utf8), statusCode: 200)
            }
            let image = #"{"partId":"1","mimeType":"image/png","filename":"logo.png","headers":[{"name":"Content-Id","value":"<logo>"}],"body":{"attachmentId":"FRESH","size":5}}"#
            return GmailHTTPResponse(data: Data(#"{"id":"m","payload":{"partId":"","mimeType":"multipart/related","parts":[\#(image)]}}"#.utf8), statusCode: 200)
        }
    }

    @Test("An embedded image is looked up in its message and then downloaded")
    func embeddedImageDownload() async throws {
        let transport = EmbeddedTransport()
        let api = GmailAPI(transport: transport) { "token" }
        let data = try await api.embeddedImageData(contentID: "logo", messageID: "m")
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        let requests = await transport.requests
        #expect(requests.count == 2)
        // The lookup leaves out the message text, which can be large.
        let fields = URLComponents(url: try #require(requests.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "fields" }?.value
        #expect(fields?.hasPrefix("id,payload(") == true)
        #expect(fields?.contains("data") == false)
    }

    @Test("A cid: URL with no matching image in the message downloads nothing")
    func embeddedImageMissing() async {
        let transport = EmbeddedTransport()
        let api = GmailAPI(transport: transport) { "token" }
        await #expect(throws: GmailError.http(404)) { try await api.embeddedImageData(contentID: "other", messageID: "m") }
        #expect(await transport.requests.count == 1)
    }

    @Test("A hostile message ID in an embedded image lookup is rejected before a request is made")
    func embeddedImageHostileID() async {
        let transport = EmbeddedTransport()
        let api = GmailAPI(transport: transport) { "token" }
        await #expect(throws: GmailError.invalidResponse) { try await api.embeddedImageData(contentID: "logo", messageID: "m/../x") }
        #expect(await transport.requests.isEmpty)
    }

    @Test("File names cannot escape or hide")
    func fileNames() {
        #expect(AttachmentFiles.fileName("../../etc/passwd") == "-..-etc-passwd")
        #expect(AttachmentFiles.fileName(".hidden") == "hidden")
        #expect(AttachmentFiles.fileName("  ") == "attachment")
        #expect(AttachmentFiles.fileName("report.pdf") == "report.pdf")
    }

    private actor Transport: GmailTransport {
        var paths: [String] = []
        func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/attachments/OLD") { return GmailHTTPResponse(data: Data(), statusCode: 404) }
            if path.hasSuffix("/attachments/NEW") {
                return GmailHTTPResponse(data: Data(#"{"data":"aGVsbG8"}"#.utf8), statusCode: 200)
            }
            let payload = #"{"partId":"","mimeType":"multipart/mixed","parts":[{"partId":"1","mimeType":"text/plain","filename":"a.txt","body":{"attachmentId":"NEW","size":5}}]}"#
            return GmailHTTPResponse(data: Data(#"{"id":"m","payload":\#(payload)}"#.utf8), statusCode: 200)
        }
    }

    @Test("A reissued attachment ID is looked up again by part")
    func reissuedID() async throws {
        let transport = Transport()
        let api = GmailAPI(transport: transport) { "token" }
        let stale = MailAttachment(messageID: "m", partID: "1", attachmentID: "OLD", filename: "a.txt", mimeType: "text/plain", size: 5)
        let data = try await api.attachmentData(stale)
        #expect(String(decoding: data, as: UTF8.self) == "hello")
        #expect(await transport.paths.count == 3)
    }

    @Test("Hostile identifiers are rejected before a request is made")
    func hostileIDs() async {
        let transport = Transport()
        let api = GmailAPI(transport: transport) { "token" }
        let hostile = MailAttachment(messageID: "m/../x", partID: "1", attachmentID: "A", filename: "a", mimeType: "text/plain", size: 1)
        await #expect(throws: GmailError.invalidResponse) { try await api.attachmentData(hostile) }
        #expect(await transport.paths.isEmpty)
    }
}

@Suite("Rate limiting")
struct RateLimitTests {
    private actor Transport: GmailTransport {
        var responses: [GmailHTTPResponse]
        private(set) var calls = 0
        init(_ responses: [GmailHTTPResponse]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
            calls += 1
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
    }

    private let limited = GmailHTTPResponse(data: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8), statusCode: 403)
    private let ok = GmailHTTPResponse(data: Data(#"{"id":"INBOX","messagesUnread":3}"#.utf8), statusCode: 200)

    @Test("A rate-limited request is retried and then succeeds")
    func retries() async throws {
        let transport = Transport([limited, GmailHTTPResponse(data: Data(), statusCode: 429), ok])
        let api = GmailAPI(transport: transport, retryDelays: [0, 0, 0]) { "token" }
        #expect(try await api.unreadInboxCount() == 3)
        #expect(await transport.calls == 3)
    }

    @Test("Staying rate-limited reports one clear error after the retries run out")
    func givesUp() async {
        let transport = Transport([limited])
        let api = GmailAPI(transport: transport, retryDelays: [0, 0]) { "token" }
        await #expect(throws: GmailError.http(429)) { try await api.unreadInboxCount() }
        #expect(await transport.calls == 3)
    }

    @Test("A real permission error is not retried")
    func deniedIsNotRetried() async {
        let transport = Transport([GmailHTTPResponse(data: Data(#"{"error":{"errors":[{"reason":"forbidden"}]}}"#.utf8), statusCode: 403)])
        let api = GmailAPI(transport: transport, retryDelays: [0, 0]) { "token" }
        await #expect(throws: GmailError.http(403)) { try await api.unreadInboxCount() }
        #expect(await transport.calls == 1)
    }
}
