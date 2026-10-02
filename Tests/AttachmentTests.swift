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
