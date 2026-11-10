import Foundation

/// Calendar errors must not turn every 403 (including a disabled API) into a sign-in loop.
nonisolated enum GoogleCalendarError: LocalizedError, Equatable, Sendable {
    case permissionRequired
    case authenticationRequired
    case wrongAccount
    case apiDisabled(projectNumber: String?)
    case http(Int)
    case unavailable

    var requiresReconnect: Bool {
        switch self {
        case .permissionRequired, .authenticationRequired: true
        default: false
        }
    }

    var setupURL: URL? {
        guard case .apiDisabled(let project) = self else { return nil }
        var url = URLComponents(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")!
        if let project, !project.isEmpty, project.allSatisfy({ $0.isASCII && $0.isNumber }) {
            url.queryItems = [URLQueryItem(name: "project", value: project)]
        }
        return url.url
    }

    var errorDescription: String? {
        switch self {
        case .permissionRequired: String(localized: "Calendar access was not granted. Your mail still works normally.")
        case .authenticationRequired: String(localized: "Your Calendar authorization has expired. Reconnect Google Calendar to try again.")
        case .wrongAccount: String(localized: "Choose the same Google account to connect its calendar. No account was changed.")
        case .apiDisabled: String(localized: "Google Calendar API is disabled for this app's Google Cloud project. Reconnecting will not fix this. Enable the API, then refresh your response.")
        case .http(403): String(localized: "Google Calendar access was denied (HTTP 403). Check your Google Workspace policy or this app's configuration.")
        case .http(429): String(localized: "Google Calendar is temporarily rate-limiting requests. Try refreshing shortly.")
        case .http(let code): String(localized: "Google Calendar could not complete the request (HTTP \(code)). Try refreshing.")
        case .unavailable: String(localized: "Could not read your Calendar response. Check your connection, then try refreshing.")
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct Failure: Decodable {
            struct Reason: Decodable { let reason: String? }
            struct Detail: Decodable {
                let reason: String?
                let metadata: [String: String]?
            }
            let errors: [Reason]?
            let details: [Detail]?
        }
        let error: Failure?
    }

    static func fromHTTP(_ response: GmailHTTPResponse) -> GoogleCalendarError {
        if response.statusCode == 401 { return .authenticationRequired }
        let error = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.data))?.error
        let reasons = Set((error?.errors ?? []).compactMap(\.reason) + (error?.details ?? []).compactMap(\.reason))
        if reasons.contains("SERVICE_DISABLED") || reasons.contains("accessNotConfigured") {
            let consumer = error?.details?.first { $0.reason == "SERVICE_DISABLED" }?.metadata?["consumer"]
            let project = consumer.flatMap { $0.hasPrefix("projects/") ? String($0.dropFirst("projects/".count)) : nil }
            return .apiDisabled(projectNumber: project)
        }
        if reasons.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || reasons.contains("insufficientPermissions") {
            return .permissionRequired
        }
        return .http(response.statusCode)
    }

    static func fromLookup(_ error: any Error) -> GoogleCalendarError {
        if let error = error as? GoogleCalendarError { return error }
        switch error as? GmailError {
        case .signInRequired, .http(401): return .authenticationRequired
        case .permissionRequired: return .permissionRequired
        case .http(let code): return .http(code)
        default: return .unavailable
        }
    }
}
