# Changelog

All notable changes to Postie are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Postie uses
[semantic versioning](https://semver.org/).

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
