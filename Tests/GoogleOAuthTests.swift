import CryptoKit
import Foundation
import Testing
@testable import Postie

/// Answers token requests from a script and remembers what was sent.
actor TokenTransport: GmailTransport {
    typealias Responder = @Sendable (_ form: [String: String]) -> (Int, String)
    private let responder: Responder
    private(set) var forms: [[String: String]] = []

    init(_ responder: @escaping Responder) { self.responder = responder }

    func send(_ request: URLRequest) async throws -> GmailHTTPResponse {
        var form: [String: String] = [:]
        for pair in String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { form[parts[0]] = parts[1].removingPercentEncoding }
        }
        forms.append(form)
        let (status, body) = responder(form)
        return GmailHTTPResponse(data: Data(body.utf8), statusCode: status)
    }
}

enum OAuthFixtures {
    static let clientID = "123-abc.apps.googleusercontent.com"
    static let allScopes = "openid email profile \(GoogleOAuthClient.gmailModifyScope) \(GoogleOAuthClient.gmailSendScope)"

    static func idToken(sub: String, email: String, name: String? = nil) -> String {
        var claims: [String: Any] = ["sub": sub, "email": email]
        if let name { claims["name"] = name }
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        return "header.\(payload).signature"
    }

    static func tokenBody(sub: String = "u1", email: String = "a@example.com", scope: String = allScopes,
                          refreshToken: String? = "refresh-1", accessToken: String = "access-1") -> String {
        var object: [String: Any] = [
            "access_token": accessToken, "expires_in": 3600, "scope": scope,
            "id_token": idToken(sub: sub, email: email, name: "Alex")
        ]
        if let refreshToken { object["refresh_token"] = refreshToken }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

@Suite("Google OAuth")
struct GoogleOAuthTests {
    let client = GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: TokenTransport { _ in (200, "{}") })

    @Test("The redirect uses the dot-reversed client ID")
    func redirect() {
        #expect(client.redirectScheme == "com.googleusercontent.apps.123-abc")
        #expect(client.redirectURI == "com.googleusercontent.apps.123-abc:/oauthredirect")
    }

    @Test("The PKCE challenge is the SHA-256 of the verifier")
    func pkce() {
        let pkce = GoogleOAuthClient.makePKCE()
        #expect(pkce.challenge == Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncoded)
        #expect(pkce.verifier.count >= 43)
        #expect(GoogleOAuthClient.makePKCE().verifier != pkce.verifier)
    }

    @Test("The authorization URL asks for both Gmail scopes with PKCE and an account chooser")
    func authorizationURL() throws {
        let pkce = GoogleOAuthClient.makePKCE()
        let url = client.authorizationURL(pkce, loginHint: "a@example.com")
        let items = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == OAuthFixtures.clientID)
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == pkce.state)
        #expect(items["prompt"] == "select_account")
        #expect(items["login_hint"] == "a@example.com")
        let scopes = Set((items["scope"] ?? "").split(separator: " ").map(String.init))
        #expect(scopes.isSuperset(of: GoogleOAuthClient.requiredScopes))
    }

    @Test("The redirect is checked against the request's state")
    func callback() throws {
        let pkce = GoogleOAuthClient.makePKCE()
        let good = URL(string: "\(client.redirectURI)?code=abc&state=\(pkce.state)")!
        #expect(try client.authorizationCode(from: good, expecting: pkce) == "abc")
        let forged = URL(string: "\(client.redirectURI)?code=abc&state=other")!
        #expect(throws: GoogleAuthError.stateMismatch) { try client.authorizationCode(from: forged, expecting: pkce) }
        let denied = URL(string: "\(client.redirectURI)?error=access_denied&state=\(pkce.state)")!
        #expect(throws: GoogleAuthError.cancelled) { try client.authorizationCode(from: denied, expecting: pkce) }
    }

    @Test("The account identity comes from the ID token")
    func identity() throws {
        let identity = try GoogleOAuthClient.identity(fromIDToken: OAuthFixtures.idToken(sub: "42", email: "a@example.com", name: "Alex"))
        #expect(identity == GoogleIdentity(id: "42", email: "a@example.com", name: "Alex"))
        #expect(throws: GmailError.invalidResponse) { try GoogleOAuthClient.identity(fromIDToken: "garbage") }
        #expect(throws: GmailError.invalidResponse) {
            try GoogleOAuthClient.identity(fromIDToken: OAuthFixtures.idToken(sub: "42", email: ""))
        }
    }

    @Test("Exchanging a code sends the verifier and returns identity and credentials")
    func exchange() async throws {
        let transport = TokenTransport { _ in (200, OAuthFixtures.tokenBody()) }
        let client = GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: transport)
        let pkce = GoogleOAuthClient.makePKCE()
        let (identity, credentials) = try await client.exchange(code: "code-1", pkce: pkce)
        #expect(identity.id == "u1")
        #expect(credentials.refreshToken == "refresh-1")
        #expect(credentials.grants(GoogleOAuthClient.requiredScopes))
        let form = try #require(await transport.forms.first)
        #expect(form["code"] == "code-1")
        #expect(form["code_verifier"] == pkce.verifier)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["redirect_uri"] == client.redirectURI)
    }

    @Test("Refreshing keeps the refresh token Google does not resend")
    func refresh() async throws {
        let transport = TokenTransport { _ in (200, OAuthFixtures.tokenBody(refreshToken: nil, accessToken: "access-2")) }
        let client = GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: transport)
        let old = GoogleCredentials(refreshToken: "refresh-1", accessToken: "access-1", expiresAt: .distantPast, scopes: [])
        let refreshed = try await client.refresh(old)
        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-1")
        #expect(refreshed.isFresh())
        #expect(!old.isFresh())
    }

    @Test("A revoked grant asks for a new sign-in; other failures stay transient")
    func failures() async throws {
        let old = GoogleCredentials(refreshToken: "r", accessToken: "a", expiresAt: .distantPast, scopes: [])
        let revoked = GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: TokenTransport { _ in (400, #"{"error":"invalid_grant"}"#) })
        await #expect(throws: GmailError.signInRequired) { try await revoked.refresh(old) }
        let outage = GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: TokenTransport { _ in (503, "") })
        await #expect(throws: GmailError.http(503)) { try await outage.refresh(old) }
    }
}
