/// A reading preference only; never changes stored or outgoing message content.
nonisolated enum MessageTextSize {
    static let defaultSize = 13
    static let range = 10...26

    static func clamped(_ size: Int) -> Int {
        min(max(size, range.lowerBound), range.upperBound)
    }

    static func scale(for size: Int) -> Double {
        Double(clamped(size)) / Double(defaultSize)
    }
}
