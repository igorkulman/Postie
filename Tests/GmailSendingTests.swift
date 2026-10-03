import Foundation
import Testing
@testable import Postie

private actor ThreadHeaderTransport: GmailTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        if request.httpMethod == "GET" {
            let json = #"{"id":"a1","messages":[{"id":"m1","internalDate":"1000","payload":{"headers":[{"name":"Message-Id","value":"<old@x>"}]}},{"id":"m2","internalDate":"2000","payload":{"headers":[{"name":"Message-ID","value":"<last@x>"},{"name":"References","value":"<old@x>"}]}}]}"#
            return GmailHTTPResponse(data: Data(json.utf8), statusCode: 200)
        }
        return GmailHTTPResponse(data: Data("{}".utf8), statusCode: 200)
    }
}

private func decode(raw: String) throws -> String {
    var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    let data = try #require(Data(base64Encoded: base64))
    return String(decoding: data, as: UTF8.self)
}

private func payload(of request: URLRequest) throws -> [String: String] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
}

@Suite("Gmail sending", .timeLimit(.minutes(1)))
struct GmailSendingTests {
    private let message = OutgoingMessage(from: "me@example.com", to: "a@example.com, b@example.com", cc: "c@example.com",
                                          subject: "Hello", body: "Line one\nLine two")

    @Test("Messages are plain-text UTF-8 with base64 bodies and the expected headers")
    func mimeStructure() throws {
        let text = String(decoding: GmailMessageBuilder.rfc822(message, date: Date(timeIntervalSince1970: 0), messageID: "<id@postie>"), as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let head = parts[0]
        let body = parts.dropFirst().joined()
        #expect(head.contains("From: me@example.com"))
        #expect(head.contains("To: a@example.com, b@example.com"))
        #expect(head.contains("Cc: c@example.com"))
        #expect(head.contains("Subject: Hello"))
        #expect(head.contains("Message-ID: <id@postie>"))
        #expect(head.contains("Date: Thu, 01 Jan 1970 00:00:00 +0000") || head.contains("Date: Thu, 01 Jan 1970"))
        #expect(head.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(head.contains("Content-Transfer-Encoding: base64"))
        #expect(!head.contains("In-Reply-To"))
        let decoded = try #require(Data(base64Encoded: body, options: .ignoreUnknownCharacters))
        #expect(String(decoding: decoded, as: UTF8.self) == "Line one\r\nLine two")
    }

    @Test("Bcc is a header, and attachments turn the message into multipart/mixed")
    func bccAndAttachments() throws {
        var withFile = message
        withFile.bcc = "hidden@example.com"
        withFile.attachments = [OutgoingAttachment(filename: "Plan \"v2\".pdf", mimeType: "application/pdf", data: Data("PDF".utf8))]
        let text = String(decoding: GmailMessageBuilder.rfc822(withFile), as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n")[0]
        #expect(head.contains("Bcc: hidden@example.com"))
        #expect(head.contains("Content-Type: multipart/mixed; boundary="))
        #expect(text.contains("Content-Type: text/plain; charset=UTF-8"))
        #expect(text.contains("Content-Type: application/pdf; name=\"Plan 'v2'.pdf\""))
        #expect(text.contains("Content-Disposition: attachment; filename=\"Plan 'v2'.pdf\""))
        #expect(text.contains(Data("PDF".utf8).base64EncodedString()))
        let boundary = try #require(head.components(separatedBy: "boundary=\"").last?.components(separatedBy: "\"").first)
        #expect(text.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test("Replies carry In-Reply-To and the accumulated References chain")
    func threadingHeaders() {
        let text = String(decoding: GmailMessageBuilder.rfc822(message, inReplyTo: "<last@x>", references: "<old@x>"), as: UTF8.self)
        #expect(text.contains("In-Reply-To: <last@x>"))
        #expect(text.contains("References: <old@x> <last@x>"))
    }

    @Test("Line breaks in user input cannot inject headers")
    func headerInjection() {
        var hostile = message
        hostile.subject = "Hi\r\nBcc: evil@example.com"
        hostile.to = "a@example.com\nBcc: evil@example.com"
        let text = String(decoding: GmailMessageBuilder.rfc822(hostile), as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n")[0]
        #expect(head.components(separatedBy: "\r\n").allSatisfy { !$0.hasPrefix("Bcc:") })
    }

    @Test("Non-ASCII subjects use RFC 2047 words that stay within line limits")
    func encodedSubject() throws {
        let subject = "Podrobnosti rezervace — přesunutá na říjen, děkujeme za váš čas a trpělivost"
        let encoded = GmailMessageBuilder.encodedSubject(subject)
        let lines = encoded.components(separatedBy: "\r\n ")
        #expect(lines.count > 1)
        #expect(lines.allSatisfy { $0.hasPrefix("=?UTF-8?B?") && $0.hasSuffix("?=") && $0.count <= 76 })
        let joined = try lines.map { line -> String in
            let payload = line.dropFirst("=?UTF-8?B?".count).dropLast(2)
            let data = try #require(Data(base64Encoded: String(payload)))
            return String(decoding: data, as: UTF8.self)
        }.joined()
        #expect(joined == subject)
        #expect(GmailMessageBuilder.encodedSubject("Plain") == "Plain")
    }

    @Test("A new message posts a raw payload without a thread")
    func sendNew() async throws {
        let transport = ThreadHeaderTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        try await api.send(message)
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/gmail/v1/users/me/messages/send")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let body = try payload(of: request)
        #expect(body["threadId"] == nil)
        let raw = try #require(body["raw"])
        #expect(try decode(raw: raw).contains("Subject: Hello"))
    }

    @Test("A reply threads on the newest message's Message-ID")
    func sendReply() async throws {
        let transport = ThreadHeaderTransport()
        let api = GmailAPI(transport: transport) { "fixture-token" }
        var reply = message
        reply.threadID = "a1"
        try await api.send(reply)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST"])
        let body = try payload(of: requests[1])
        #expect(body["threadId"] == "a1")
        let raw = try #require(body["raw"])
        let mime = try decode(raw: raw)
        #expect(mime.contains("In-Reply-To: <last@x>"))
        #expect(mime.contains("References: <old@x> <last@x>"))
    }

    @Test("Send failures propagate")
    func failure() async {
        let api = GmailAPI(transport: FixtureTransport(mode: .denied)) { "t" }
        await #expect(throws: GmailError.http(401)) { try await api.send(message) }
    }

    @Test("Reply drafts address the other party and forwards start fresh threads")
    @MainActor
    func drafts() {
        let mine = MailMessage(id: "mine", senderName: "Me", senderEmail: "me@example.com", recipient: "a@example.com", cc: "c@example.com",
                               date: Date(), body: "Hi")
        let theirs = MailMessage(id: "theirs", senderName: "A", senderEmail: "a@example.com", recipient: "me@example.com", cc: "c@example.com",
                                 date: Date(), body: "Hello")
        let thread = MailThread(id: "plans", subject: "Plans", messages: [mine, theirs], mailbox: .inbox)
        let reply = ComposeDraft.reply(to: thread, accountEmail: "ME@example.com", allRecipients: true)
        #expect(reply.recipient == "a@example.com")
        #expect(reply.cc == "c@example.com")
        #expect(reply.subject == "Re: Plans")
        #expect(ComposeDraft.forward(thread).subject == "Fwd: Plans")
    }
}
