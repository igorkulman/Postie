import AppKit
import AuthenticationServices

/// Shows Google's sign-in page and returns the redirect URL.
@MainActor
protocol WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// The system web authentication session: the same sign-in sheet Safari uses, so passkeys and
/// saved Google sessions work, and no embedded web view ever sees the password.
@MainActor
final class SystemWebSignIn: NSObject, WebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable callback, error in
                    // AuthenticationServices calls this on its own queue, so it must not be main-actor isolated.
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: GoogleAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? GmailError.invalidResponse)
                    }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { continuation.resume(throwing: GmailError.invalidResponse) }
            }
        } onCancel: {
            Task { @MainActor in self.session?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? ASPresentationAnchor()
    }
}
