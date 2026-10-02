# Postie

A small native Gmail client for macOS, built with SwiftUI.

Postie is for people who want a simple Mac email client without Electron,
subscriptions, AI features, or workspace bloat.

![Postie](docs/postie.png)

## Features

- Native SwiftUI macOS app
- Gmail integration using Google Sign-In and the Gmail API
- Inbox, Sent, Archive, Junk, and Trash, plus a read-only view of Drafts
- Conversation view with HTML email rendering
- Compose, reply, reply all, and forward (plain text)
- Archive, trash, star, and read/unread actions
- Local SQLite cache for previously loaded mail
- Incremental Gmail synchronization while the app is running
- Local search across loaded mail
- Native light and dark mode
- Dock badge for unread Inbox mail

## Status

Postie is an early project that I built primarily as the Gmail client I wanted
to use myself.

It currently supports a single Gmail account and is not intended to replace
every feature of Gmail or become a generic IMAP client.

Planned:

- Attachments and CID images
- Saving and syncing drafts (the Drafts folder is view-only for now)
- Gmail labels
- Rich-text composing (messages are plain text for now)
- An offline send queue (mail is sent immediately, so the Outbox is always empty)
- Full offline mailbox downloads
- Multiple accounts

Not planned:

- Generic IMAP / Exchange support
- Push notifications while Postie is closed

## Privacy and permissions

Postie talks to Gmail directly from your Mac. There is no Postie server.

It asks for two Gmail permissions:

- `gmail.modify` to read mail and to archive, trash, star, and mark mail as read
  or unread
- `gmail.send` to send mail

Postie never permanently deletes mail. Trash is Gmail's normal, recoverable
Trash. Sign-in credentials stay in the Google Sign-In SDK's Keychain storage,
and loaded mail is cached in a local SQLite database on your Mac.

Both permissions are restricted Gmail scopes. Until Google verifies the app,
only accounts added as test users can sign in, and their sign-in expires after
7 days. If you fork Postie, create your own OAuth client in Google Cloud and put
it in `Configuration/Google.local.xcconfig` (see the `.example` file).

## Requirements

- macOS 26
- Xcode 27

## Running Postie

Open `Postie.xcodeproj`, choose the **Postie** scheme and **My Mac**, and run.

## Screenshots with sample data

Launch Postie with the `-PostieDemoData` argument (Xcode: Scheme > Run >
Arguments) to start on built-in sample mail instead of a real account.

## Tests

Run the **Postie** scheme's tests (⌘U). They use fixtures and need neither a
Google account nor network access.
