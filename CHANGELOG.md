# Changelog

All notable changes to Postie are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Postie uses
[semantic versioning](https://semver.org/).

## [Unreleased]

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
