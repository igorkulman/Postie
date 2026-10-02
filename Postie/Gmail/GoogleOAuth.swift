import CryptoKit
import Foundation

nonisolated struct GoogleIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Google's stable user ID (the `sub` claim). Survives email changes.
    let id: String
    let email: String
    let name: String?
}

nonisolated struct GoogleCredentials: Codable, Equatable, Sendable {
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var scopes: Set<String>

    func isFresh(at now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) > 60 }
    func grants(_ required: [String]) -> Bool { required.allSatisfy(scopes.contains) }
}

nonisolated enum GoogleAuthError: Error, Equatable {
    /// The person closed the sign-in window. Not worth showing an error for.
    case cancelled
    case denied(String)
    case stateMismatch
}

extension GoogleAuthError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled: nil
        case .denied(let reason): String(localized: "Google sign-in was not completed (\(reason)).")
        case .stateMismatch: String(localized: "Google sign-in returned an unexpected response. Please try again.")
        }
    }
}

/// OAuth 2.0 for installed apps with PKCE. No client secret: the client is a public one.
nonisolated struct GoogleOAuthClient: Sendable {
    // Reading plus archive/trash. Narrower than full mailbox access: no permanent delete.
    static let gmailModifyScope = "https://www.googleapis.com/auth/gmail.modify"
    static let gmailSendScope = "https://www.googleapis.com/auth/gmail.send"
    static let requiredScopes = [gmailModifyScope, gmailSendScope]

    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    let clientID: String
    let transport: any GmailTransport

    init(clientID: String, transport: any GmailTransport = GmailURLTransport()) {
        self.clientID = clientID
        self.transport = transport
    }

    /// Google's iOS-style clients redirect to the dot-reversed client ID.
    var redirectScheme: String { clientID.split(separator: ".").reversed().joined(separator: ".") }
    var redirectURI: String { redirectScheme + ":/oauthredirect" }

    struct PKCE: Sendable {
        let verifier: String
        let challenge: String
        let state: String
    }

    static func makePKCE() -> PKCE {
        let verifier = randomToken(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        return PKCE(verifier: verifier, challenge: challenge, state: randomToken(byteCount: 16))
    }

    private static func randomToken(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
    }

    func authorizationURL(_ pkce: PKCE, loginHint: String? = nil) -> URL {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: (["openid", "email", "profile"] + Self.requiredScopes).joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            // Adding a second account must offer the account chooser, not reuse the browser session.
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// Reads the authorization code from the redirect, checking `state` against the request.
    func authorizationCode(from callback: URL, expecting pkce: PKCE) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? GoogleAuthError.cancelled : GoogleAuthError.denied(error)
        }
        guard value("state") == pkce.state else { throw GoogleAuthError.stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw GmailError.invalidResponse }
        return code
    }

    func exchange(code: String, pkce: PKCE) async throws -> (identity: GoogleIdentity, credentials: GoogleCredentials) {
        let response = try await token(form: [
            "client_id": clientID, "code": code, "code_verifier": pkce.verifier,
            "grant_type": "authorization_code", "redirect_uri": redirectURI
        ])
        guard let refreshToken = response.refreshToken, let idToken = response.idToken else { throw GmailError.invalidResponse }
        return (
            try Self.identity(fromIDToken: idToken),
            GoogleCredentials(
                refreshToken: refreshToken, accessToken: response.accessToken,
                expiresAt: Date().addingTimeInterval(response.expiresIn), scopes: response.grantedScopes
            )
        )
    }

    func refresh(_ credentials: GoogleCredentials) async throws -> GoogleCredentials {
        let response = try await token(form: [
            "client_id": clientID, "refresh_token": credentials.refreshToken, "grant_type": "refresh_token"
        ])
        var refreshed = credentials
        refreshed.accessToken = response.accessToken
        refreshed.expiresAt = Date().addingTimeInterval(response.expiresIn)
        if let refreshToken = response.refreshToken { refreshed.refreshToken = refreshToken }
        if !response.grantedScopes.isEmpty { refreshed.scopes = response.grantedScopes }
        return refreshed
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?
        let scope: String?
        let idToken: String?

        var grantedScopes: Set<String> { Set((scope ?? "").split(separator: " ").map(String.init)) }
    }

    private struct TokenError: Decodable { let error: String? }

    private func token(form: [String: String]) async throws -> TokenResponse {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { Self.percentEncode($0.key) + "=" + Self.percentEncode($0.value) }
            .joined(separator: "&").utf8)
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            // A revoked or expired grant needs a new sign-in; anything else may be transient.
            let error = (try? JSONDecoder().decode(TokenError.self, from: response.data))?.error
            if error == "invalid_grant" { throw GmailError.signInRequired }
            throw GmailError.http(response.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(TokenResponse.self, from: response.data) }
        catch { throw GmailError.invalidResponse }
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    /// The ID token comes straight from Google's token endpoint over TLS, so its payload is trusted without verifying the signature.
    static func identity(fromIDToken token: String) throws -> GoogleIdentity {
        struct Claims: Decodable { let sub: String; let email: String?; let name: String? }
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              !claims.sub.isEmpty, let email = claims.email, !email.isEmpty else { throw GmailError.invalidResponse }
        return GoogleIdentity(id: claims.sub, email: email, name: claims.name)
    }
}

extension Data {
    nonisolated var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
