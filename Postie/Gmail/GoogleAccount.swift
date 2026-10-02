import AppKit
import GoogleSignIn
import Observation

@MainActor
@Observable
final class GoogleAccount {
    // Reading plus archive/trash. Narrower than full mailbox access: no permanent delete or sending.
    static let gmailModifyScope = "https://www.googleapis.com/auth/gmail.modify"

    static let gmailSendScope = "https://www.googleapis.com/auth/gmail.send"
    static let requiredScopes = [gmailModifyScope, gmailSendScope]

    private(set) var email: String?
    private(set) var accountID: String?
    private(set) var isBusy = false
    private(set) var error: String?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var cache: GmailCache?

    func useCache(_ cache: GmailCache) { self.cache = cache }

    var configurationIssue: String? {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("YOUR_") else {
            return String(localized: "Add your OAuth client to Configuration/Google.local.xcconfig, then rebuild. See README for setup.")
        }
        let expectedScheme = clientID.split(separator: ".").reversed().joined(separator: ".")
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        guard types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(expectedScheme) == true }) else {
            return String(localized: "GOOGLE_REVERSED_CLIENT_ID must match the dot-reversed client ID. Update the local configuration and rebuild.")
        }
        return nil
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        guard configurationIssue == nil, GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            try Task.checkCancellation()
            try accept(user)
        } catch {
            if !(error is CancellationError) { self.error = String(localized: "Your Google session could not be restored. Sign in again to continue.") }
        }
    }

    func signIn() {
        guard !isBusy, configurationIssue == nil else { return }
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else {
            error = String(localized: "No window is available to present Google sign-in.")
            return
        }
        isBusy = true
        error = nil
        // The account owns this finite task. Signing out cancels it.
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.signInTask = nil }
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: window, hint: nil, additionalScopes: Self.requiredScopes
                )
                try Task.checkCancellation()
                try self.accept(result.user)
            } catch {
                let sdkError = error as NSError
                if !(error is CancellationError), !(sdkError.domain == kGIDSignInErrorDomain && sdkError.code == GIDSignInError.Code.canceled.rawValue) {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func accessToken() async throws -> String {
        guard email != nil, let user = GIDSignIn.sharedInstance.currentUser else { throw GmailError.signInRequired }
        let refreshed = try await user.refreshTokensIfNeeded()
        try Task.checkCancellation()
        guard email != nil, refreshed.userID == GIDSignIn.sharedInstance.currentUser?.userID else { throw GmailError.signInRequired }
        guard Self.requiredScopes.allSatisfy({ refreshed.grantedScopes?.contains($0) == true }) else { throw GmailError.permissionRequired }
        return refreshed.accessToken.tokenString
    }

    func signOut() async {
        signInTask?.cancel()
        do {
            if let cache, let accountID { try await cache.removeAccount(id: accountID) }
            GIDSignIn.sharedInstance.signOut()
            accountID = nil
            email = nil
            error = nil
        } catch {
            // Do not claim a successful logout while leaving an offline account cache behind.
            self.error = String(localized: "Unable to remove locally cached mail. Sign-out was not completed.")
        }
    }

    private func accept(_ user: GIDGoogleUser) throws {
        guard Self.requiredScopes.allSatisfy({ user.grantedScopes?.contains($0) == true }) else { throw GmailError.permissionRequired }
        guard let id = user.userID, !id.isEmpty,
              let email = user.profile?.email, !email.isEmpty else { throw GmailError.invalidResponse }
        accountID = id
        self.email = email
        error = nil
    }
}
