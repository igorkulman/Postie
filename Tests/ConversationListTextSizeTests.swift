import Testing
@testable import Postie

struct ConversationListTextSizeTests {
    @Test("Saved list sizes stay between the 13 pt default and 200 percent enlargement", arguments: [
        (saved: -100, expected: 13),
        (saved: 13, expected: 13),
        (saved: 20, expected: 20),
        (saved: 100, expected: 26)
    ])
    func boundedSize(example: (saved: Int, expected: Int)) {
        #expect(ConversationListTextSize.clamped(example.saved) == example.expected)
    }
}
