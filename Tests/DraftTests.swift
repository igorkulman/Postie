import Foundation
import Testing
@testable import Postie

private actor DraftTransport: GmailTransport {
    private(set) var requests: [URLRequest] = []
    var drafts: [(id: String, messageID: String)] = []

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        let path = request.url?.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: "") ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "drafts"):
            return reply(#"{"id":"d1","message":{"id":"m1","threadId":"t1"}}"#)
        case ("PUT", "drafts/d1"):
            return reply(#"{"id":"d1","message":{"id":"m2","threadId":"t1"}}"#)
        case ("POST", "drafts/send"):
            return reply(#"{"id":"m2","threadId":"t1"}"#)
        case ("DELETE", "drafts/gone"):
            return GmailHTTPResponse(data: Data(), statusCode: 404)
        case ("DELETE", _):
            return GmailHTTPResponse(data: Data(), statusCode: 204)
        case ("GET", "labels/DRAFT"):
            return reply(#"{"messagesTotal":3}"#)
        case ("GET", "drafts"):
            let page = request.url?.query?.contains("pageToken=next") == true
            return reply(page ? #"{"drafts":[{"id":"d9","message":{"id":"m9"}}]}"#
                              : #"{"drafts":[{"id":"d1","message":{"id":"m1"}}],"nextPageToken":"next"}"#)
        case ("GET", "drafts/d9"):
            let text = Data("Hello".utf8).base64EncodedString()
            let html = Data("<div>Hello</div>".utf8).base64EncodedString()
            return reply("""
            {"id":"d9","message":{"id":"m9","threadId":"t9","payload":{"mimeType":"multipart/alternative","headers":[
            {"name":"Subject","value":"Plans"},{"name":"To","value":"a@x.com"},{"name":"Bcc","value":"b@x.com"},
            {"name":"In-Reply-To","value":"<o@x>"}],"parts":[
            {"mimeType":"text/plain","body":{"data":"\(text)"}},{"mimeType":"text/html","body":{"data":"\(html)"}}]}}}
            """)
        case ("GET", _):
            // Thread headers for threading a reply: the draft itself must not be picked as the original.
            return reply(#"{"id":"t1","messages":[{"id":"m1","labelIds":["INBOX"],"internalDate":"1000","payload":{"headers":[{"name":"Message-ID","value":"<o@x>"}]}},{"id":"m2","labelIds":["DRAFT"],"internalDate":"2000","payload":{"headers":[{"name":"Message-ID","value":"<draft@x>"}]}}]}"#)
        default:
            return GmailHTTPResponse(data: Data("{}".utf8), statusCode: 200)
        }
    }

    private func reply(_ json: String) -> GmailHTTPResponse { GmailHTTPResponse(data: Data(json.utf8), statusCode: 200) }
}

@Suite("Gmail drafts", .timeLimit(.minutes(1)))
struct GmailDraftAPITests {
    private let message = OutgoingMessage(from: "me@x.com", to: "", subject: "Hi", body: "Text")

    @Test("A draft is created once, then replaced by ID, and may have no recipient")
    func createAndUpdate() async throws {
        let transport = DraftTransport()
        let api = GmailAPI(transport: transport) { "t" }
        let created = try await api.saveDraft(message, draftID: nil)
        #expect(created == GmailDraftRef(id: "d1", messageID: "m1", threadID: "t1"))
        let updated = try await api.saveDraft(message, draftID: "d1")
        #expect(updated.messageID == "m2")
        let requests = await transport.requests
        #expect(requests.map { ($0.httpMethod ?? "", $0.url?.path ?? "") }.map { "\($0.0) \($0.1)" }
                == ["POST /gmail/v1/users/me/drafts", "PUT /gmail/v1/users/me/drafts/d1"])
        let data = try #require(requests[0].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        let raw = try #require(body["message"]?["raw"])
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let text = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
        #expect(!text.contains("\r\nTo:"))
        #expect(text.contains("Subject: Hi"))
    }

    @Test("Sending a draft saves its latest content, then sends it by ID")
    func sendDraft() async throws {
        let transport = DraftTransport()
        try await GmailAPI(transport: transport) { "t" }.sendDraft(message, draftID: "d1")
        let requests = await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(requests == ["PUT /gmail/v1/users/me/drafts/d1", "POST /gmail/v1/users/me/drafts/send"])
        let sent = try #require(await transport.requests.last?.httpBody)
        #expect(String(decoding: sent, as: UTF8.self).contains("d1"))
    }

    @Test("A reply draft threads onto the last real message, not onto a draft")
    func threadingSkipsDrafts() async throws {
        var reply = message
        reply.threadID = "t1"
        let transport = DraftTransport()
        _ = try await GmailAPI(transport: transport) { "t" }.saveDraft(reply, draftID: nil)
        let body = try #require(await transport.requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String: String]])
        var base64 = try #require(json["message"]?["raw"]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let text = String(decoding: try #require(Data(base64Encoded: base64)), as: UTF8.self)
        #expect(text.contains("In-Reply-To: <o@x>"))
        #expect(!text.contains("<draft@x>"))
        #expect(json["message"]?["threadId"] == "t1")
    }

    @Test("A draft already deleted elsewhere is not an error")
    func deleteMissing() async throws {
        let api = GmailAPI(transport: DraftTransport()) { "t" }
        try await api.deleteDraft(id: "d1")
        try await api.deleteDraft(id: "gone")
    }

    @Test("The draft behind a message is found across pages")
    func findsDraft() async throws {
        let api = GmailAPI(transport: DraftTransport()) { "t" }
        #expect(try await api.draftID(forMessage: "m9") == "d9")
        #expect(try await api.draftID(forMessage: "nope") == nil)
    }

    @Test("The number of drafts comes from Gmail's DRAFT label")
    func countsDrafts() async throws {
        #expect(try await GmailAPI(transport: DraftTransport()) { "t" }.draftCount() == 3)
    }

    @Test("A draft's content is read back for editing")
    func readsContent() async throws {
        let content = try await GmailAPI(transport: DraftTransport()) { "t" }.draftContent(id: "d9")
        #expect(content.subject == "Plans")
        #expect(content.to == "a@x.com")
        #expect(content.bcc == "b@x.com")
        #expect(content.text == "Hello")
        #expect(content.html == "<div>Hello</div>")
        #expect(content.isReply)
        #expect(content.ref.threadID == "t9")
    }
}

@MainActor
@Suite("Draft session", .timeLimit(.minutes(1)))
struct DraftSessionTests {
    @MainActor final class Store {
        var saved: [(subject: String, ref: DraftRef?)] = []
        var deleted: [DraftRef] = []
        var claimed: [DraftRef] = []
        var released: [DraftRef] = []
        var failing = false
        var accountID = "acct"

        var storage: DraftStorage {
            DraftStorage(
                save: { [self] draft, ref in
                    try await Task.sleep(for: .milliseconds(20))
                    if failing { throw GmailError.http(500) }
                    saved.append((draft.subject, ref))
                    return DraftRef(accountID: draft.accountID ?? accountID, draftID: "d\(ref == nil ? saved.count : 1)")
                },
                delete: { [self] in deleted.append($0) },
                claim: { [self] ref, _ in claimed.append(ref) },
                release: { [self] in released.append($0) }
            )
        }
    }

    private func draft(_ subject: String, account: String? = "acct") -> ComposeDraft {
        ComposeDraft(recipient: "a@x.com", subject: subject, body: "Hi", accountID: account)
    }

    @Test("Overlapping saves create the draft once and the rest replace it")
    func queuesSaves() async {
        let store = Store()
        let session = DraftSession(storage: store.storage)
        async let first: Void = session.save(draft("One"))
        async let second: Void = session.save(draft("Two"))
        _ = await (first, second)
        #expect(store.saved.count == 2)
        #expect(store.saved[0].ref == nil)
        #expect(store.saved[1].ref == DraftRef(accountID: "acct", draftID: "d1"))
        #expect(session.state != .saving)
        #expect(session.isSaved(draft("Two")))
    }

    @Test("Saving what Gmail already has does nothing")
    func skipsUnchanged() async {
        let store = Store()
        let session = DraftSession(storage: store.storage)
        await session.save(draft("One"))
        await session.save(draft("One"))
        #expect(store.saved.count == 1)
    }

    @Test("A failed save is reported and the next one tries again")
    func failure() async {
        let store = Store()
        store.failing = true
        let session = DraftSession(storage: store.storage)
        await session.save(draft("One"))
        #expect(session.state == .failed(GmailError.http(500).localizedDescription))
        store.failing = false
        await session.save(draft("One"))
        guard case .saved = session.state else { Issue.record("not saved"); return }
    }

    @Test("Discarding deletes the saved draft and stops further saving")
    func discard() async {
        let store = Store()
        let session = DraftSession(storage: store.storage)
        await session.save(draft("One"))
        await session.discard()
        #expect(store.deleted == [DraftRef(accountID: "acct", draftID: "d1")])
        await session.save(draft("Two"))
        #expect(store.saved.count == 1)
        #expect(session.ref == nil)
    }

    @Test("A draft that was opened keeps its ID and is not saved again until it changes")
    func opened() async {
        let store = Store()
        let ref = DraftRef(accountID: "acct", draftID: "d7")
        let session = DraftSession(storage: store.storage, existing: ref)
        session.markSaved(draft("Old"))
        await session.save(draft("Old"))
        #expect(store.saved.isEmpty)
        await session.save(draft("New"))
        #expect(store.saved.first?.ref == ref)
    }

    @Test("Sending from another account removes the draft of the first one")
    func accountMismatch() async {
        let store = Store()
        let session = DraftSession(storage: store.storage)
        await session.save(draft("One"))
        #expect(await session.draftIDForSending(from: "acct") == "d1")
        #expect(await session.draftIDForSending(from: "other") == nil)
        #expect(store.deleted.count == 1)
    }

    @Test("A finished session releases the draft's window")
    func finish() async {
        let store = Store()
        let session = DraftSession(storage: store.storage)
        await session.save(draft("One"))
        session.finish()
        #expect(store.released.last == DraftRef(accountID: "acct", draftID: "d1"))
        await session.save(draft("Two"))
        #expect(store.saved.count == 1)
    }
}
