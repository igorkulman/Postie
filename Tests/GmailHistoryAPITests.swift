import Foundation
import Testing
@testable import Postie

@Suite("Gmail history REST contract", .timeLimit(.minutes(1)))
struct GmailHistoryAPITests {
    @Test("Profile supplies an exact string checkpoint, including IDs larger than Int")
    func profile() async throws {
        let transport = HistoryFixtureTransport(json: #"{"historyId":"18446744073709551615"}"#)
        let api = GmailAPI(transport: transport) { "test-token" }
        #expect(try await api.currentHistoryID() == "18446744073709551615")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path.hasSuffix("/profile") == true)
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "fields", value: "historyId")])
    }

    @Test("History uses account-wide GETs, every change type and escaped pagination tokens")
    func historyContract() async throws {
        let transport = HistoryFixtureTransport(json: #"""
        {"historyId":"110","nextPageToken":"next +/=","history":[{
          "id":"109",
          "messages":[{"id":"m1","threadId":"a1"}],
          "messagesAdded":[{"message":{"id":"m1","threadId":"a1"}}],
          "messagesDeleted":[{"message":{"id":"m2","threadId":"a2"}}],
          "labelsAdded":[{"message":{"id":"m3","threadId":"a3"},"labelIds":["TRASH"]}],
          "labelsRemoved":[{"message":{"id":"m4","threadId":"a4"},"labelIds":["INBOX"]}]
        }]}
        """#)
        let api = GmailAPI(transport: transport) { "test-token" }
        let page = try await api.history(startHistoryID: "100", pageToken: "next +/=")
        #expect(page.affectedThreadIDs == ["a1", "a2", "a3", "a4"])
        #expect(page.nextPageToken == "next +/=")
        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "startHistoryId", value: "100")))
        #expect(query.contains(URLQueryItem(name: "maxResults", value: "500")))
        #expect(query.contains(URLQueryItem(name: "pageToken", value: "next +/=")))
        #expect(!query.contains { $0.name == "labelId" || $0.name == "historyTypes" })
        #expect(url.absoluteString.contains("%2B"))
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(!url.absoluteString.contains("test-token"))
    }

    @Test("Empty history still supplies the next durable checkpoint")
    func emptyHistory() async throws {
        let api = GmailAPI(transport: HistoryFixtureTransport(json: #"{"historyId":"101"}"#)) { "test-token" }
        let page = try await api.history(startHistoryID: "100", pageToken: nil)
        #expect(page.affectedThreadIDs.isEmpty)
        #expect(page.historyId == "101")
        #expect(page.nextPageToken == nil)
    }

    @Test("Malformed checkpoints or history pointers fail closed", arguments: [
        #"{}"#, #"{"historyId":""}"#, #"{"historyId":"0"}"#, #"{"historyId":"000"}"#,
        #"{"historyId":"-1"}"#, #"{"historyId":101}"#,
        #"{"historyId":"101","history":[{"id":"100","messagesDeleted":[{"message":{"id":"m1"}}]}]}"#
    ])
    func malformed(json: String) async {
        let api = GmailAPI(transport: HistoryFixtureTransport(json: json)) { "test-token" }
        await #expect(throws: GmailError.invalidResponse) { try await api.history(startHistoryID: "100", pageToken: nil) }
    }

    @Test("Invalid starting checkpoints make no request", arguments: ["", "0", "000", "-1", "12/34", "1a", "１"])
    func invalidStart(checkpoint: String) async {
        let transport = HistoryFixtureTransport(json: #"{"historyId":"101"}"#)
        let api = GmailAPI(transport: transport) { "test-token" }
        await #expect(throws: GmailError.invalidResponse) { try await api.history(startHistoryID: checkpoint, pageToken: nil) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Only thread 404 means deletion; history 404 remains available for checkpoint recovery")
    func missingResource() async throws {
        let api = GmailAPI(transport: HistoryFixtureTransport(json: "{}", status: 404)) { "test-token" }
        #expect(try await api.metadata(id: "a1") == nil)
        await #expect(throws: GmailError.http(404)) { try await api.history(startHistoryID: "100", pageToken: nil) }
        await #expect(throws: GmailError.http(404)) { try await api.currentHistoryID() }
    }

    @Test("Changed threads are fetched without body data, never as body downloads")
    func metadata() async throws {
        let transport = HistoryFixtureTransport(data: GmailFixtures.thread("a1"))
        let api = GmailAPI(transport: transport) { "test-token" }
        let conversation = try #require(try await api.metadata(id: "a1"))
        #expect(conversation.messages.allSatisfy { !$0.bodyLoaded && $0.body.isEmpty })
        let request = try #require(await transport.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Attachments are only visible in the full format, so a field mask keeps the bodies out.
        let fields = try #require(query.first { $0.name == "fields" }?.value)
        #expect(query.contains(URLQueryItem(name: "format", value: "full")))
        #expect(fields.contains("attachmentId") && !fields.contains("data"))
    }
}

private actor HistoryFixtureTransport: GmailTransport {
    let data: Data
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(json: String, status: Int = 200) { data = Data(json.utf8); self.status = status }
    init(data: Data) { self.data = data; status = 200 }
    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        requests.append(request)
        return GmailHTTPResponse(data: data, statusCode: status)
    }
}
