import Testing
@testable import Postie

@Suite("Recipient summaries")
struct RecipientSummaryTests {
    @Test("Only the receiving account is called me, matching addresses case insensitively")
    func receivingAccount() {
        #expect(RecipientSummary.text(to: "\"Alex Example\" <ALEX@example.com>",
                                      cc: "Freddie Wollen <freddie@example.com>",
                                      accountEmail: "alex@example.com") == "To: me · Cc: Freddie Wollen")
        #expect(RecipientSummary.names(in: "Alex Example <alex@example.com>",
                                       accountEmail: "another@example.com") == "Alex Example")
    }

    @Test("Quoted commas stay in names and bare addresses remain identifiable")
    func namesAndAddresses() {
        #expect(RecipientSummary.names(in: "\"Doe, Jo\" <jo@example.com>, team@example.com",
                                       accountEmail: nil) == "Doe, Jo, team@example.com")
    }

    @Test("Empty or unparseable headers are not replaced by invented recipients")
    func missingRecipients() {
        #expect(RecipientSummary.text(to: "", cc: "", accountEmail: nil) == "Recipients not specified")
        #expect(RecipientSummary.text(to: "", cc: "Team <team@example.com>", accountEmail: nil) == "Cc: Team")
        #expect(RecipientSummary.names(in: "Undisclosed recipients:;", accountEmail: nil) == "Undisclosed recipients:;")
    }
}
