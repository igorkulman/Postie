import Testing
@testable import Postie

struct MessageTextSizeTests {
    @Test("Reading size stays usable even with an out-of-range saved preference", arguments: [
        (saved: -100, expected: 10),
        (saved: 13, expected: 13),
        (saved: 20, expected: 20),
        (saved: 100, expected: 26)
    ])
    func boundedSize(example: (saved: Int, expected: Int)) {
        #expect(MessageTextSize.clamped(example.saved) == example.expected)
    }

    @Test("Actual size preserves the sender's sizing; doubling reading size doubles HTML text")
    func proportionalHTMLSize() {
        #expect(MessageTextSize.scale(for: 13) == 1)
        #expect(MessageTextSize.scale(for: 26) == 2)
    }
}
