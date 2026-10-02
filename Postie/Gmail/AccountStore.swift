import Foundation
import Observation

/// The connected Google accounts and their credentials. Knows nothing about mail.
@MainActor
@Observable
final class AccountStore {
    struct Entry: Identifiable, Equatable {
        let identity: GoogleIdentity
        let addedAt: Date
        /// The refresh token was revoked or the Keychain entry is unusable; mail already downloaded stays readable.
        var needsReconnect = false

        var id: String { identity.id }
        var email: String { identity.email }
    }

    private(set) var accounts: [Entry] = []
    private(set) var isBusy = false
    var error: String?
    private var storedDefaultID: String?

    @ObservationIgnored private var credentials: [String: GoogleCredentials] = [:]
    @ObservationIgnored private var refreshes: [String: Task<GoogleCredentials, Error>] = [:]
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private let vault: any AccountVault
    @ObservationIgnored private let oauth: GoogleOAuthClient?
    @ObservationIgnored private let webSignIn: any WebAuthenticating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let defaultAccountKey = "defaultAccountID"

    init(
        vault: any AccountVault = KeychainAccountVault(),
        oauth: GoogleOAuthClient? = nil,
        webSignIn: (any WebAuthenticating)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.vault = vault
        // Tests pass an explicit client; the app reads the one configured in Info.plist.
        self.oauth = oauth ?? Self.configuredOAuthClient()
        self.webSignIn = webSignIn ?? SystemWebSignIn()
        self.defaults = defaults
        storedDefaultID = defaults.string(forKey: Self.defaultAccountKey)
    }

    static func configuredOAuthClient() -> GoogleOAuthClient? {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("YOUR_") else { return nil }
        return GoogleOAuthClient(clientID: clientID)
    }

    var configurationIssue: String? {
        oauth == nil
            ? String(localized: "Add your OAuth client to Configuration/Google.local.xcconfig, then rebuild. See README for setup.")
            : nil
    }

    /// The account new messages are sent from: the one chosen in Settings, else the first one added.
    var defaultAccount: Entry? {
        accounts.first { $0.id == storedDefaultID } ?? accounts.first
    }

    func setDefault(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        storedDefaultID = id
        defaults.set(id, forKey: Self.defaultAccountKey)
    }

    func restore() {
        do {
            let stored = try vault.loadAll()
            credentials = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.credentials) })
            accounts = stored.sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
                .map { Entry(identity: $0.identity, addedAt: $0.addedAt, needsReconnect: !$0.credentials.grants(GoogleOAuthClient.requiredScopes)) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Signs in a Google account and adds it. Signing in an account that is already connected renews its credentials.
    func addAccount(loginHint: String? = nil) {
        guard !isBusy, let oauth else { return }
        isBusy = true
        error = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.signInTask = nil }
            do {
                let pkce = GoogleOAuthClient.makePKCE()
                let callback = try await webSignIn.authenticate(
                    url: oauth.authorizationURL(pkce, loginHint: loginHint), callbackScheme: oauth.redirectScheme
                )
                let code = try oauth.authorizationCode(from: callback, expecting: pkce)
                let (identity, newCredentials) = try await oauth.exchange(code: code, pkce: pkce)
                try Task.checkCancellation()
                guard newCredentials.grants(GoogleOAuthClient.requiredScopes) else { throw GmailError.permissionRequired }
                try accept(identity, newCredentials)
            } catch is CancellationError {
            } catch GoogleAuthError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func reconnect(_ id: String) {
        addAccount(loginHint: accounts.first { $0.id == id }?.email)
    }

    func cancelSignIn() { signInTask?.cancel() }

    /// Forgets the account and its credentials. The caller removes the downloaded mail first.
    func remove(_ id: String) {
        do {
            try vault.delete(id: id)
        } catch {
            self.error = error.localizedDescription
            return
        }
        credentials[id] = nil
        refreshes[id]?.cancel()
        refreshes[id] = nil
        accounts.removeAll { $0.id == id }
        if storedDefaultID == id {
            storedDefaultID = nil
            defaults.removeObject(forKey: Self.defaultAccountKey)
        }
        error = nil
    }

    func accessToken(for id: String) async throws -> String {
        guard let current = credentials[id], accounts.contains(where: { $0.id == id }) else { throw GmailError.signInRequired }
        guard current.grants(GoogleOAuthClient.requiredScopes) else { throw GmailError.permissionRequired }
        if current.isFresh() { return current.accessToken }
        guard let oauth else { throw GmailError.signInRequired }
        // Concurrent requests share one refresh instead of each spending the token.
        let refresh = refreshes[id] ?? Task { try await oauth.refresh(current) }
        refreshes[id] = refresh
        do {
            let refreshed = try await refresh.value
            try Task.checkCancellation()
            guard accounts.contains(where: { $0.id == id }) else { throw GmailError.signInRequired }
            refreshes[id] = nil
            credentials[id] = refreshed
            if let entry = accounts.first(where: { $0.id == id }) {
                try? vault.save(StoredAccount(identity: entry.identity, credentials: refreshed, addedAt: entry.addedAt))
            }
            return refreshed.accessToken
        } catch {
            refreshes[id] = nil
            if case GmailError.signInRequired = error { markNeedsReconnect(id) }
            throw error
        }
    }

    private func markNeedsReconnect(_ id: String) {
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].needsReconnect = true }
    }

    private func accept(_ identity: GoogleIdentity, _ newCredentials: GoogleCredentials) throws {
        let addedAt = accounts.first { $0.id == identity.id }?.addedAt ?? Date()
        try vault.save(StoredAccount(identity: identity, credentials: newCredentials, addedAt: addedAt))
        credentials[identity.id] = newCredentials
        let entry = Entry(identity: identity, addedAt: addedAt)
        if let index = accounts.firstIndex(where: { $0.id == identity.id }) {
            accounts[index] = entry
        } else {
            accounts.append(entry)
        }
        error = nil
    }
}
