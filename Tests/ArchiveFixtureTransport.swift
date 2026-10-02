import Foundation
@testable import Postie

actor ArchiveFixtureTransport: GmailTransport {
    let labels: [String]
    init(labels: [String]) { self.labels = labels }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        if request.url?.path.hasSuffix("/threads") == true {
            return GmailHTTPResponse(data: Data(#"{"threads":[{"id":"a1"}]}"#.utf8), statusCode: 200)
        }
        var object = try JSONSerialization.jsonObject(with: GmailFixtures.thread()) as! [String: Any]
        var messages = object["messages"] as! [[String: Any]]
        for index in messages.indices { messages[index]["labelIds"] = labels }
        object["messages"] = messages
        return GmailHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}
