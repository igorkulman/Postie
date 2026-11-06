import Foundation
import Testing
@testable import Postie

/// Plays the sign-in sheet: approves immediately and echoes the request's state.
@MainActor
final class FakeWebSignIn: WebAuthenticating {
    var cancels = false
    private(set) var urls: [URL] = []

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        urls.append(url)
        if cancels { throw GoogleAuthError.cancelled }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(callbackScheme):/oauthredirect?code=code&state=\(state)")!
    }
}

@Suite("Connected accounts", .timeLimit(.minutes(1)))
@MainActor
struct AccountStoreTests {
    /// Signs in as whichever account `next` names; token refreshes succeed unless `refreshError` is set.
    final class Script: @unchecked Sendable {
        var next = (sub: "u1", email: "a@example.com")
        var scope = OAuthFixtures.allScopes
        var refreshError: String?
    }

    func makeStore(vault: MemoryAccountVault = MemoryAccountVault(), script: Script = Script(),
                   web: FakeWebSignIn = FakeWebSignIn()) -> (AccountStore, Script, FakeWebSignIn, TokenTransport) {
        let transport = TokenTransport { form in
            if form["grant_type"] == "refresh_token" {
                if let error = script.refreshError { return (400, #"{"error":"\#(error)"}"#) }
                return (200, OAuthFixtures.tokenBody(refreshToken: nil, accessToken: "refreshed"))
            }
            return (200, OAuthFixtures.tokenBody(sub: script.next.sub, email: script.next.email, scope: script.scope))
        }
        let store = AccountStore(
            vault: vault, oauth: GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: transport),
            webSignIn: web, defaults: UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)")!
        )
        return (store, script, web, transport)
    }

    func add(_ store: AccountStore, _ script: Script, sub: String, email: String) async {
        script.next = (sub, email)
        store.addAccount()
        while store.isBusy { await Task.yield() }
    }

    @Test("The selected account is the default one until another is chosen, and is remembered")
    func selectedAccount() {
        let stored = ["u1", "u2"].enumerated().map { index, id in
            StoredAccount(
                identity: GoogleIdentity(id: id, email: "\(id)@example.com", name: nil),
                credentials: GoogleCredentials(refreshToken: "r", accessToken: "t", expiresAt: .distantFuture, scopes: []),
                addedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        let vault = MemoryAccountVault(stored)
        let defaults = UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)")!
        let store = AccountStore(vault: vault, oauth: nil, defaults: defaults)
        store.restore()
        #expect(store.selectedAccount?.id == "u1")
        store.selectAccount("u2")
        #expect(store.selectedAccount?.id == "u2")
        store.selectAccount("unknown")
        #expect(store.selectedAccount?.id == "u2")

        let reopened = AccountStore(vault: vault, oauth: nil, defaults: defaults)
        reopened.restore()
        #expect(reopened.selectedAccount?.id == "u2")
    }

    @Test("Profile pictures are fetched for saved accounts and kept; a failure changes nothing")
    func profilePictures() async throws {
        let credentials = GoogleCredentials(refreshToken: "r", accessToken: "t", expiresAt: .distantFuture,
                                            scopes: Set(GoogleOAuthClient.requiredScopes))
        // Saved before Postie knew about pictures: the JSON has no such key.
        let saved = #"{"id":"u1","email":"a@example.com"}"#
        let identity = try JSONDecoder().decode(GoogleIdentity.self, from: Data(saved.utf8))
        #expect(identity.picture == nil)
        #expect(identity.initials == "A")
        let vault = MemoryAccountVault([StoredAccount(identity: identity, credentials: credentials, addedAt: Date())])

        let script = Script()
        let transport = TokenTransport { _ in (script.refreshError == nil ? 200 : 500, #"{"picture":"https://lh3.example.com/a=s96-c"}"#) }
        let store = AccountStore(vault: vault, oauth: GoogleOAuthClient(clientID: OAuthFixtures.clientID, transport: transport),
                                 defaults: UserDefaults(suiteName: "postie-tests-\(UUID().uuidString)")!)
        store.restore()
        let picture = URL(string: "https://lh3.example.com/a=s96-c")

        await store.refreshProfilePictures()
        #expect(store.accounts.first?.identity.picture == picture)
        #expect(try vault.loadAll().first?.identity.picture == picture)

        script.refreshError = "server_error"
        await store.refreshProfilePictures()
        #expect(store.accounts.first?.identity.picture == picture)
    }

    @Test("Initials come from the name, else the address")
    func initials() {
        #expect(GoogleIdentity(id: "1", email: "a@example.com", name: "alex morgan rivera").initials == "AM")
        #expect(GoogleIdentity(id: "1", email: "zed@example.com", name: nil).initials == "Z")
        #expect(GoogleIdentity(id: "1", email: "zed@example.com", name: "").initials == "Z")
    }

    @Test("The first account added is the default until another is chosen")
    func defaults() async {
        let (store, script, _, _) = makeStore()
        await add(store, script, sub: "u1", email: "a@example.com")
        await add(store, script, sub: "u2", email: "b@example.com")
        #expect(store.accounts.map(\.email) == ["a@example.com", "b@example.com"])
        #expect(store.defaultAccount?.id == "u1")
        store.setDefault("u2")
        #expect(store.defaultAccount?.id == "u2")
        store.remove("u2")
        #expect(store.defaultAccount?.id == "u1")
        store.setDefault("missing")
        #expect(store.defaultAccount?.id == "u1")
    }

    @Test("Accounts and their order survive a relaunch")
    func persistence() async {
        let vault = MemoryAccountVault()
        let (first, script, _, _) = makeStore(vault: vault)
        await add(first, script, sub: "u1", email: "a@example.com")
        await add(first, script, sub: "u2", email: "b@example.com")
        let (second, _, _, _) = makeStore(vault: vault)
        second.restore()
        #expect(second.accounts.map(\.id) == ["u1", "u2"])
        #expect(second.accounts.allSatisfy { !$0.needsReconnect })
    }

    @Test("Signing in an existing account renews it without reordering")
    func reconnect() async {
        let (store, script, _, _) = makeStore()
        await add(store, script, sub: "u1", email: "a@example.com")
        await add(store, script, sub: "u2", email: "b@example.com")
        let added = store.accounts[0].addedAt
        await add(store, script, sub: "u1", email: "a@example.com")
        #expect(store.accounts.map(\.id) == ["u1", "u2"])
        #expect(store.accounts[0].addedAt == added)
    }

    @Test("Closing the sign-in sheet is not an error")
    func cancelling() async {
        let (store, script, web, _) = makeStore()
        web.cancels = true
        await add(store, script, sub: "u1", email: "a@example.com")
        #expect(store.accounts.isEmpty)
        #expect(store.error == nil)
    }

    @Test("An account that withheld a Gmail permission is not added")
    func missingScope() async {
        let (store, script, _, _) = makeStore()
        script.scope = "openid email profile \(GoogleOAuthClient.gmailModifyScope)"
        await add(store, script, sub: "u1", email: "a@example.com")
        #expect(store.accounts.isEmpty)
        #expect(store.error != nil)
    }

    @Test("Concurrent requests share one token refresh")
    func sharedRefresh() async throws {
        let stale = StoredAccount(
            identity: GoogleIdentity(id: "u1", email: "a@example.com", name: nil),
            credentials: GoogleCredentials(refreshToken: "r", accessToken: "old", expiresAt: .distantPast,
                                           scopes: Set(GoogleOAuthClient.requiredScopes)),
            addedAt: Date()
        )
        let vault = MemoryAccountVault([stale])
        let (store, _, _, transport) = makeStore(vault: vault)
        store.restore()
        async let one = store.accessToken(for: "u1")
        async let two = store.accessToken(for: "u1")
        #expect(try await [one, two] == ["refreshed", "refreshed"])
        #expect(await transport.forms.count == 1)
        #expect(try vault.loadAll().first?.credentials.accessToken == "refreshed")
        #expect(try await store.accessToken(for: "u1") == "refreshed")
        #expect(await transport.forms.count == 1)
    }

    @Test("A revoked account asks to reconnect and a removed one has no token")
    func revoked() async throws {
        let (store, script, _, _) = makeStore()
        await add(store, script, sub: "u1", email: "a@example.com")
        script.refreshError = "invalid_grant"
        // Force a refresh by replacing the credentials with expired ones.
        let vaultAccount = StoredAccount(
            identity: store.accounts[0].identity,
            credentials: GoogleCredentials(refreshToken: "r", accessToken: "old", expiresAt: .distantPast, scopes: Set(GoogleOAuthClient.requiredScopes)),
            addedAt: store.accounts[0].addedAt
        )
        let (restored, _, _, _) = makeStore(vault: MemoryAccountVault([vaultAccount]), script: script)
        restored.restore()
        await #expect(throws: GmailError.signInRequired) { try await restored.accessToken(for: "u1") }
        #expect(restored.accounts.first?.needsReconnect == true)
        restored.remove("u1")
        await #expect(throws: GmailError.signInRequired) { try await restored.accessToken(for: "u1") }
    }
}
