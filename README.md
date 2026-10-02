# Postie

A small native macOS email-client prototype, built with SwiftUI.

## Current state

**A read-only Gmail reader, plus an interactive sample-data demo. Sending real email is not implemented.**

### Gmail reader

- Connect one Google account using Google Sign-In; authentication is persisted by the SDK in Keychain
- Browse Inbox, Drafts, Sent, Archive, Junk, and Trash in pages of 25, with bounded metadata requests
- Show an empty local Outbox until sending is implemented
- Load full conversations when selected; open multi-message threads at the expanded newest message's header
- Synchronize Gmail changes on launch/reconnection, app activation, and roughly every minute while running
- Refresh manually with Get New Mail (Shift-Command-N); the next page loads automatically at the end of the list
- Show the total unread Inbox message count on the Dock icon; update on initial load and folder refresh, hide at zero, and retain the last known count if its request fails
- Render HTML formatting with restricted WebKit; keep plain text for search and fallback
- Load remote HTTP(S) images automatically; block email scripts, external stylesheets/fonts, forms, and automatic navigation
- Open clicked HTTP(S)/mailto links outside the reader
- Preserve Gmail IDs, custom/system labels, and read/star state without modifying the mailbox
- Search the current folder's loaded/cached headers and snippets, plus downloaded message bodies
- Restore loaded folder pages and previously opened plain-text/HTML bodies from a local SQLite cache
- Show saved mail before connecting to Google; keep cached mail visible if refresh or session restoration fails
- Show loading, retry, and pagination states; switching folders clears the previous folder's selection and pagination
- Account and Dock-badge preferences, including sign out, live in Settings (Command-,)

`gmail.modify` and `gmail.send` are requested in addition to Google's basic sign-in scopes. Gmail API requests are GETs, except archive (removes the Inbox label) and move to Trash (recoverable, never permanent delete). Starring and read/unread use label changes on the thread. Sending (compose, reply, reply all, forward; plain text, no attachments) uses `gmail.send`; Gmail drafts are not synced. Opening a conversation marks it read in Gmail after one second.

Loaded Gmail mail is persisted locally using GRDB/SQLite; see **Local cache** below. HTTP responses and remote images still have no persistent cache. The HTML renderer uses nonpersistent website storage, a restrictive content security policy, and a compiled content blocker installed before loading any email. If that setup or rendering fails, it shows plain text instead. Remote HTTP(S) images load automatically, including tracking pixels: senders may learn your IP address and when you opened a message. Remote stylesheets, fonts, scripts, frames, and other non-image resources remain blocked. Inline data images are supported; CID images and other attachments are not yet fetched. Previously downloaded message bodies can be read offline; unopened bodies, remote images, and attachments still require a connection or are unsupported. Incremental history sync and periodic refresh run while the app is open; there is no push service or app-closed delivery. Bodies requiring attachment downloads are not fetched.

### Sample-data demo

Choose **Explore the Demo** on the connection screen to try the existing interactive prototype. Its actions affect sample mail only:

- Compact three-column layout with Inbox, Drafts, Outbox, Sent, Archive, Junk, and Trash
- Search across sample subjects, senders, recipients, and message bodies
- Dense message rows and an unboxed reading pane with expandable messages, read state, and stars
- Native toolbar: compose above the message list; Archive, Delete, Reply, Reply All, and Forward above the reader
- Archive and Delete move conversations into browsable demo folders; no messages are permanently deleted
- Compose, reply, reply-all, and forward, with multiple To/Cc recipients, validation, and discard confirmation
- Save drafts and add messages to the demo Sent mailbox
- Light and dark appearances using system colors and the system accent
- Command-N to compose; Command-Return to send a demo message
- Update the Dock badge as demo Inbox conversations are read, archived, or moved to Trash

Demo messages and drafts live in memory and reset when the app quits. Sample addresses use `example.com`.

## Run

Open `Postie.xcodeproj` in Xcode, choose the **Postie** scheme and **My Mac**, and run.

The app target currently requires macOS 26.0. Xcode resolves Google Sign-In and GRDB automatically. The project uses Xcode's file-system-synchronized build folders: new Swift files under `Postie/` are discovered automatically. No project generator is used.

### Configure Gmail

The app builds without OAuth configuration; Gmail sign-in stays disabled until configured. No backend, client secret, or API key is needed.

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/) and enable the **Gmail API**.
2. Configure the Google Auth Platform consent screen for your app. During development, use **Testing** and add your Google account as a test user. Add `https://www.googleapis.com/auth/gmail.modify` to the app's data-access scopes. This is a restricted scope; public distribution requires Google's verification planning.
3. Create an OAuth client with application type **iOS**, **even for this macOS app**, as required by Google Sign-In. Register the app's bundle identifier (`sk.kulman.Postie` unless you change it in Xcode). Use your own Apple Team ID if the console requests it. A Desktop or Web OAuth client is not interchangeable with this configuration.
4. Open `Configuration/Google.local.xcconfig`. If it does not exist, duplicate `Google.local.xcconfig.example` and name the copy `Google.local.xcconfig`. Do not overwrite an existing configured file. Fill in both identifiers:

   ```xcconfig
   GOOGLE_CLIENT_ID = 123-example.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.123-example
   ```

   Use your actual client ID and its dot-reversed value (the console's **iOS URL scheme**), not these example values. The app's Info.plist and URL scheme use this configuration automatically.
5. In Xcode's **Signing & Capabilities**, select your own development team and use an Apple-issued signing certificate. Google's macOS Keychain integration requires certificate signing, not just an ad-hoc signature. Network-client and Keychain entitlements are already configured.
6. Rebuild and run, then choose **Sign in with Google** and grant read-only Gmail access.

The local xcconfig is Git-ignored. OAuth client IDs are public identifiers; do not put secrets or access/refresh tokens in it. The SDK stores credentials in Keychain; the app never writes tokens to preferences or logs. Use Settings → Account → Sign Out to remove saved mail and the local session. Revoke Google's consent grant separately in your Google account settings if needed.

External apps in Testing can have refresh tokens expire after seven days; sign in again when prompted. Workspace administrator policies can also block access.

## Local cache

The cache stores loaded pages and relevant incremental changes, not your entire Gmail account:

- SQLite lives at `Application Support/Postie/mail.sqlite` inside the app's sandbox container.
- A versioned migration stores accounts, threads, messages, per-message labels, loaded folder snapshots, pagination tokens, refresh timestamps, and the last known unread Inbox count.
- Rows are scoped by Google's stable account ID, not by the email address. Credentials remain exclusively in the SDK's Keychain storage.
- Metadata refresh updates labels and preserves downloaded bodies by message ID. Draft bodies are invalidated on metadata refresh because drafts can change in place.
- Opening a saved message does not require another body download. A new, undownloaded reply shows its snippet and a clear explanation if offline.
- Normal refresh applies Gmail history to loaded pages without replacing them or clearing downloaded bodies. Initial/expired-history snapshots fetch first pages and reconcile older cached threads. Load More still fetches older pages on demand. Absence from one page is not evidence of account-wide deletion.
- A sync/database failure retains the previous cache and checkpoint for retry. If opening the database fails, the app falls back to online-only reading without deleting it.
- Settings → Account → Sign Out removes that account's cached rows and revokes outstanding cache writers.
- The database is **not application-encrypted**. The directory/file use owner-only permissions, and SQLite secure deletion is enabled for the on-disk database; this is not a guarantee of forensic erasure from filesystem snapshots or backups. FileVault provides system-level protection when enabled.
- The demo remains memory-only. Hosted tests and previews never open the real user's mail database.

## Gmail synchronization

- An account-scoped `historyID` checkpoint lives in SQLite. Initial sync captures a profile baseline **before** fetching folder snapshots, then replays intervening changes.
- Every account-wide history page is consumed without Inbox-only/type filters. Changed thread IDs are deduplicated and current metadata is fetched with at most six concurrent requests.
- New messages/replies, removed messages, label/read/star changes, folder moves, and permanent deletions update loaded folder projections. Immutable downloaded bodies are preserved; mutable drafts are invalidated.
- One transaction applies mail, labels, deletions, folder ordering, and the final checkpoint. A failed page, metadata request, account-reset cancellation, or database transaction does not advance it.
- Expired-history HTTP 404 rebuilds relevant snapshots and reconciles older cached threads without blanking usable mail first. Failed rebuilds retain the old cache/checkpoint.
- Overlapping refreshes/folder changes share one owned account sync. Cancelling a view waiter does not abort shared sync; account reset/sign-out does. A newer committed checkpoint prevents stale body/page downloads from overwriting it.
- Refresh runs on launch/reconnection, activation, Get New Mail, and approximately every 60 seconds while the main window is open, including when another app is frontmost. There is no app-closed agent or push service.
- The Dock badge still uses Gmail's complete unread Inbox message count, not a count inferred from the partial cache.

### Manual cache verification

Load two Inbox pages, open a plain-text and an HTML conversation, visit Sent, then quit. Disable networking and relaunch: saved folder rows, the unread badge, and opened bodies should remain available. An unopened body should explain that it has not been downloaded. Reconnect with **Reconnect Gmail** if Google session restoration failed, or use Get New Mail if the existing session is still available. Confirm a successful metadata refresh retains opened bodies. Remote images are not saved for offline use.

### Manual sync verification

Load multiple Inbox pages and open a conversation. In Gmail, mark it read/starred, archive another loaded thread, permanently delete another, and send a new message/reply. Confirm the next minute's refresh (or Get New Mail) updates rows, folder membership, the unread badge, and the new reply without discarding older downloaded bodies/pages. Repeat while Postie is inactive, then return to check activation refresh. Offline sync should report failure while cached mail remains usable; reconnect and refresh to recover. Expired-history recovery is tested with fixtures rather than requiring a week-old real checkpoint.

## Structure

- `Postie/ContentView.swift`: mailbox navigation and selection
- `Postie/Views/`: conversation, composer, and shared UI
- `Postie/Models/`: sample data and observable demo mailbox
- `Postie/Gmail/`: authentication, GET-only REST client, wire/domain types, cache-backed reader state, and the GRDB database/migration
- `Configuration/`: OAuth build configuration, URL scheme, and sandbox/Keychain entitlements
- `Tests/`: Swift Testing suites in the `PostieTests` Xcode unit-test target
- `Postie.xctestplan`: the shared unit-test plan used by the `Postie` scheme

## Unit tests

Select the **Postie** scheme and **My Mac**, then press **Command-U** (Product → Test). Individual tests and parameterized cases also appear in Xcode's **Test Navigator** (Command-6). The shared scheme uses the **Postie** test plan and builds the `PostieTests` target. No shell runners or separate Swift executables are needed.

Tests use `@testable import Postie` to exercise the actual app module. The demo suites cover filtering, read/star state, drafts, archive/trash, addressing, forwarding, validation, and simulated sends. Gmail suites cover folder queries, REST request construction, pagination, bounded fan-out, MIME/header parsing, read-only behavior, retries, cancellation, and stale results after selection/folder changes or reset. Conversation tests cover the opening scroll-target policy for single, empty, long, and HTML threads; they do not verify runtime scrolling. HTML tests compile the actual WebKit content rules and load fixture messages to verify styling, inline data images, disabled page scripts, and image-only resource exceptions and blocked unsupported resources/forms/navigation.

The tests are deterministic and require no OAuth configuration or real Gmail account. Network responses are supplied by fixtures. The test plan sets `POSTIE_UNIT_TESTS=1`, which disables automatic Google session restoration in the hosted app so tests cannot silently use saved account credentials. Unread-count tests cover Gmail's complete Inbox total, zero/invalid values, refresh failures, folder switches, resets, cancellation, and request ordering. Persistence tests reopen temporary databases, exercise offline reader restoration, body-preserving metadata merges, mutable drafts, pagination, account isolation/removal, lease revocation, and stale/cancelled requests. Sync tests cover baseline replay, history pagination/deduplication, body retention, message/thread deletion, transactional rollback, durable account-scoped checkpoints, expired-history recovery/failure, overlapping refreshes, cancelled waiters/account resets, and stale writes. Hosted tests disable production mail persistence and Dock updates; cache previews use an in-memory database. Real sign-in and UI interactions still need the manual verification below.

### Manual Gmail verification

After configuring OAuth, sign in with your test account; compare each folder and a multi-message conversation with Gmail. Archive contains received mail outside Inbox, Drafts, Junk, and Trash; Outbox stays empty until sending is implemented. Compare the Dock badge with Gmail's total unread Inbox message count (not just the currently loaded conversations); switch to Sent or Archive and confirm it still represents Inbox. Mark messages read in Gmail, refresh Postie with Command-R, and verify the badge updates or disappears at zero. An offline refresh must retain the previous badge. In the demo, reading, archiving, or deleting unread Inbox conversations should reduce the badge. Confirm unread/star state is unchanged after reading real Gmail mail. Exercise Load More, folder switches, local search, Command-R, and an offline refresh and retry. Relaunch to verify Keychain session restoration. Confirm all write actions are disabled and the account/logout toolbar menu is absent. Open a long conversation: its newest message should be expanded and its header visible at the top. Scroll up or expand earlier messages; later HTML/image resizing must not pull you back to the newest message. Single-message emails should still show their subject. Compare a real HTML email with Gmail in light/dark appearances and a narrow reader pane; confirm its layout and remote images are displayed, links open externally, and scrolling and message expansion behave correctly. Email scripts, forms, external stylesheets/fonts, and automatic redirects must remain blocked. SwiftUI preview snapshots may be captured before WebKit's asynchronous content load completes; they do not establish HTML rendering correctness.

## Next

Add sending and mailbox mutations with separately granted scopes. The small REST client uses Foundation; a generated Gmail SDK can be introduced if the API surface grows.

CID images/attachments, full-account offline downloads, multi-account UI, full-text search indexing, push notifications, and app-closed delivery are not implemented.

## Integration references

- [Google Sign-In setup for iOS and macOS](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google Sign-In lifecycle](https://developers.google.com/identity/sign-in/ios/sign-in)
- [Calling Google APIs with refreshed credentials](https://developers.google.com/identity/sign-in/ios/api-access)
- [Gmail thread listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/list)
- [Gmail synchronization](https://developers.google.com/workspace/gmail/api/guides/sync)
- [Gmail history listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list)
- [Gmail message and MIME resources](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages)
- [WebKit page JavaScript controls](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)
- [WebKit content blockers](https://developer.apple.com/documentation/webkit/wkcontentrulelist)

A distribution license has not been selected yet.
