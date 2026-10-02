# iMail

A small native macOS email-client prototype, built with SwiftUI.

## Current state

**UI demo only. Gmail is not connected. No real email is received or sent.**

- Compact three-column layout with Inbox, Sent, Drafts, Archive, and Trash
- Search across sample subjects, senders, recipients, and message bodies
- Dense message rows and an unboxed reading pane with expandable messages, read state, and stars
- Native toolbar: compose above the message list; Archive, Delete, Reply, Reply All, and Forward above the reader
- Archive and Delete move conversations into browsable demo folders; no messages are permanently deleted
- Compose, reply, reply-all, and forward, with multiple To/Cc recipients, validation, and discard confirmation
- Save drafts and add messages to the demo Sent mailbox
- Light and dark appearances using system colors and the system accent
- Command-N to compose; Command-Return to send a demo message

All messages and drafts live in memory and reset when the app quits. Sample addresses use `example.com`.

## Run

Open `iMail.xcodeproj` in Xcode, choose the **iMail** scheme and **My Mac**, and run.

The existing project targets macOS 26.7. The project uses Xcode's file-system-synchronized build folders: new Swift files under `iMail/` are discovered automatically. No project generator is used.

## Structure

- `iMail/ContentView.swift`: mailbox navigation and selection
- `iMail/Views/`: conversation, composer, and shared UI
- `iMail/Models/`: sample data and observable demo mailbox
- `Tests/MailStoreChecks.swift`: lightweight automated checks outside the app target

Run the model checks with the Swift toolchain selected by Xcode:

```sh
bash Scripts/check-mail-store.sh
```

These cover filtering, search, read/star state, draft updates/deletion, archive/trash behavior, reply/reply-all addressing, forwarding, validation, and simulated sends. They do not verify UI interactions.

## Next: Gmail

Replace the in-memory demo service with Google Sign-In and Google's `GoogleAPIClientForREST_Gmail` Swift Package Manager product. Keep SDK-specific models out of the views.

The next slice should connect one account and fetch real inbox conversations, then add send/reply. This needs a Google Cloud project, the Gmail API enabled, OAuth configuration, and a configured test user. Reading Gmail uses a restricted OAuth scope; public distribution requires planning for Google's verification requirements.

HTML rendering, attachments, offline persistence, multiple accounts, and background delivery are not implemented.

A distribution license has not been selected yet.
