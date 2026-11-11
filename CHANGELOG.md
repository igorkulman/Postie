# Changelog

All notable changes to Postie are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Postie uses
[semantic versioning](https://semver.org/).

## [Unreleased]

## [0.5.0] - 2026-11-11

### Added

- Separate message-list text size setting in Settings > General, from 13 pt up to
  26 pt. Sender names, subjects, previews, and metadata scale together,
  independently of message-body zoom.
- Previous and next conversation controls, including keyboard shortcuts, and
  easier access to earlier replies in a conversation.
- Mailbox loading, search, and pagination status, plus progress indicators for
  archive and trash actions.

### Changed

- Larger default text in the message list for more comfortable reading.
- Conversation subjects stay visible above scrolling messages.
- Simpler recipient headers with expandable addresses, clearer conversation
  counts, and more readable text widths without changing authored HTML layouts.

### Fixed

- New conversations retain their full row height instead of clipping subjects
  and previews.
- Mail is automatically marked as read only while its reader window is active.

## [0.4.0] - 2026-11-10

### Added

- Calendar invitation cards with event details and Accept, Maybe and Decline
  responses sent through the Gmail account that received the invitation.
- Optional read-only Google Calendar access to show your existing response status.
- Reading text size controls under View > Text Size: Bigger (⌘+), Smaller (⌘−)
  and Actual Size (⌘0). The preference is remembered for HTML and plain-text
  email bodies.

### Fixed

- Automatic update checks are now enabled by default, while respecting an
  explicit choice to disable them in Settings.

## [0.3.0] - 2026-10-14

### Changed

- The conversation list no longer has a footer; more mail loads as you scroll.
- When Gmail rate-limits Postie, all requests now pause together and retry on a
  longer schedule instead of each backing off on its own.

### Fixed

- Conversations that were deleted outright are no longer fetched again and again
  during sync, which only produced errors.

## [0.2.0] - 2026-10-09

### Added

- A real Outbox: sent messages are saved on this Mac and delivered in the
  background, retried when the connection or Gmail is unavailable, and kept
  across quitting. Messages that cannot be sent stay in the Outbox, where they
  can be sent again, edited or deleted.
- Automatic updates: Postie checks for new releases in the background and
  installs them on request. Use Postie > Check for Updates… to check right now,
  or turn the automatic check off in Settings.

### Changed

- Message bodies are fetched in the background ahead of time, so conversations
  open faster, and a spinner shows while a body is still loading.

### Upgrading

- Version 0.1.0 cannot update itself. Download 0.2.0 from the
  [latest release](https://github.com/igorkulman/Postie/releases/latest) once;
  later versions will be offered inside Postie.

## [0.1.0] - 2026-10-07

First public release.

### Added

- Native SwiftUI Gmail client for macOS 26, with Google sign-in and the Gmail API
- Multiple Gmail accounts merged into one set of folders, with replies, forwards
  and archive/trash actions going through the account a conversation belongs to
- Inbox, Drafts, Sent, Archive, Junk and Trash
- Conversation view with HTML email rendering, scrolling long messages with the
  conversation and collapsing quoted history
- Rich-text compose, reply, reply all and forward with attachments and your
  Gmail signature
- Drafts saved in Gmail and editable from the Drafts folder
- Address suggestions from your Google contacts
- Search as you type across all accounts, in the current folder or All Mail
- Reading, opening, saving, sharing and copying attachments
- Archive, trash, star and read/unread actions
- Local SQLite cache and incremental synchronization
- Dock badge for unread Inbox mail
- Native light and dark mode

### Known limitations

- Postie is not verified by Google, so the sign-in screen shows "Google hasn't
  verified this app" (choose **Advanced > Go to Postie (unsafe)**) and the app is
  limited to 100 users
- No Gmail labels, CID (embedded) images or offline send queue yet

[0.1.0]: https://github.com/igorkulman/Postie/releases/tag/v0.1.0
[0.2.0]: https://github.com/igorkulman/Postie/releases/tag/v0.2.0
[0.3.0]: https://github.com/igorkulman/Postie/releases/tag/v0.3.0
[0.4.0]: https://github.com/igorkulman/Postie/releases/tag/v0.4.0
[0.5.0]: https://github.com/igorkulman/Postie/releases/tag/v0.5.0
