import os

/// One logger per area, so Console.app and `log stream` can filter with
/// `subsystem == "sk.kulman.Postie" AND category == "sync"`.
///
/// Never log message content, addresses, subjects or tokens. Interpolated values are private by
/// default; only mark something `.public` when it can never identify a person or their mail.
nonisolated enum Log {
    private static let subsystem = "sk.kulman.Postie"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let accounts = Logger(subsystem: subsystem, category: "accounts")
    static let attachments = Logger(subsystem: subsystem, category: "attachments")
}
