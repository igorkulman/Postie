import Foundation

enum SampleMail {
    static func threads(now: Date = Date()) -> [MailThread] {
        // Sample mail gets stable IDs, so the same sample always has the same identity.
        var issued = 0
        func nextID(_ kind: String) -> String {
            issued += 1
            return "sample-\(kind)-\(issued)"
        }

        func message(_ name: String, _ email: String, _ minutesAgo: Double, _ body: String) -> MailMessage {
            MailMessage(
                id: nextID("message"), senderName: name, senderEmail: email,
                recipient: SampleAccount.email,
                date: now.addingTimeInterval(-minutesAgo * 60), body: body
            )
        }

        return [
            MailThread(
                id: nextID("thread"),
                subject: "A little room to breathe",
                messages: [
                    message("Sophie Chen", "sophie@example.com", 120, """
                    Hey Alex,

                    I've been thinking about our next project. What if we made something smaller, slower, and a little more thoughtful?

                    Not another dashboard. Just a quiet place to do one thing well.

                    I'd love to hear what you think.
                    Sophie
                    """),
                    message("Sophie Chen", "sophie@example.com", 12, """
                    Hey Alex,

                    I put together a few ideas for the direction we talked about. The more I look at them, the more I think we should keep things simple.

                    Plenty of space. A warm, neutral palette. Details that feel considered, without getting in the way.

                    The goal isn't to add more — it's to make the everyday feel a little better.

                    Are you free for a coffee tomorrow? I'd love to walk you through it.

                    Sophie
                    """)
                ], mailbox: .inbox
            ),
            MailThread(
                id: nextID("thread"),
                subject: "Your weekend, well spent",
                messages: [message("The Sunday Edit", "hello@example.com", 48, """
                A few good things for your weekend.

                A long walk without a destination. A book you've been meaning to start. A recipe worth taking your time with.

                This week's recommendation: close the laptop a little earlier.

                See you next Sunday.
                """)], mailbox: .inbox, isUnread: true
            ),
            MailThread(
                id: nextID("thread"),
                subject: "Coffee on Thursday?",
                messages: [message("James Wilson", "james@example.com", 95, """
                Hi Alex,

                I'll be in your neighborhood on Thursday morning. Want to catch up at the usual spot around 10?

                It's been far too long.

                James
                """)], mailbox: .inbox, isUnread: true, isStarred: true
            ),
            MailThread(
                id: nextID("thread"),
                subject: "The first version is ready",
                messages: [message("Maya Patel", "maya@example.com", 240, """
                Hi Alex,

                The first version is ready for a look. We focused on the essentials and left the rest for later.

                Let me know what feels right, and what needs a little more attention.

                Thanks,
                Maya
                """)], mailbox: .inbox, isUnread: true
            ),
            MailThread(
                id: nextID("thread"),
                subject: "A table for two",
                messages: [message("Juniper Kitchen", "reservations@example.com", 1260, """
                Hello Alex,

                Your table is confirmed for Friday at 7:30 PM, for two guests.

                We look forward to welcoming you.

                Juniper Kitchen
                """)], mailbox: .inbox
            ),
            MailThread(
                id: nextID("thread"),
                subject: "Notes from our walk",
                messages: [message("Oliver Brooks", "oliver@example.com", 1500, """
                Alex,

                A small reminder of the things we talked about:

                Make time for the good work.
                Say no a little more often.
                Take the scenic route.

                Same time next week?

                Oliver
                """)], mailbox: .inbox, isStarred: true
            ),
            MailThread(
                id: nextID("thread"),
                subject: "Thanks for a lovely evening",
                messages: [MailMessage(
                    id: nextID("message"), senderName: SampleAccount.name, senderEmail: SampleAccount.email,
                    recipient: "sophie@example.com", date: now.addingTimeInterval(-86400),
                    body: "Hi Sophie,\n\nThanks for having us over. Such a lovely evening — let's do it again soon.\n\nAlex"
                )], mailbox: .sent
            )
        ]
    }
}
