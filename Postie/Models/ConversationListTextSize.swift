/// Independent of message-body zoom. Metadata scales with the list's primary text.
nonisolated enum ConversationListTextSize {
    static let defaultSize = 13
    static let range = 13...26

    static func clamped(_ size: Int) -> Int {
        min(max(size, range.lowerBound), range.upperBound)
    }
}
