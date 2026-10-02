# iMail

A small native macOS email-client prototype, built with SwiftUI.

## Current state

**A read-only Gmail reader, plus an interactive sample-data demo. Sending real email is not implemented.**

### Gmail reader

- Connect one Google account using Google Sign-In; authentication is persisted by the SDK in Keychain
- Browse Inbox, Drafts, Sent, Archive, Junk, and Trash in pages of 25, with bounded metadata requests
- Show an empty local Outbox until sending is implemented
- Load full conversations when selected
- Refresh the current folder manually with Command-R
- Render HTML formatting with restricted WebKit; keep plain text for search and fallback
- Load remote HTTP(S) images automatically; block email scripts, external stylesheets/fonts, forms, and automatic navigation
- Open clicked HTTP(S)/mailto links outside the reader
- Preserve Gmail IDs, custom/system labels, and read/star state without modifying the mailbox
- Search loaded conversation headers and snippets, plus bodies already fetched in this session
- Show loading, retry, and pagination states; switching folders clears the previous folder's selection and pagination
- No account toolbar icon or logout menu; proper account settings will be added later

Only `gmail.readonly` is requested in addition to Google's basic sign-in scopes. All Gmail API requests are GETs. Compose, archive, trash, reply, forward, and changing stars are disabled in Gmail mode. Opening a conversation does **not** mark it read in Gmail.

Email is held in memory, with no database or on-disk HTTP cache. The HTML renderer uses nonpersistent website storage, a restrictive content security policy, and a compiled content blocker installed before loading any email. If that setup or rendering fails, it shows plain text instead. Remote HTTP(S) images load automatically, including tracking pixels: senders may learn your IP address and when you opened a message. Remote stylesheets, fonts, scripts, frames, and other non-image resources remain blocked. Inline data images are supported; CID images and other attachments are not yet fetched. There is no offline mode or automatic background refresh. Bodies requiring attachment downloads are not fetched.

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

Demo messages and drafts live in memory and reset when the app quits. Sample addresses use `example.com`.

## Run

Open `iMail.xcodeproj` in Xcode, choose the **iMail** scheme and **My Mac**, and run.

The app target currently requires macOS 26.0. Xcode resolves the Google Sign-In package automatically. The project uses Xcode's file-system-synchronized build folders: new Swift files under `iMail/` are discovered automatically. No project generator is used.

### Configure Gmail

The app builds without OAuth configuration; Gmail sign-in stays disabled until configured. No backend, client secret, or API key is needed.

1. Create or select a project in [Google Cloud Console](https://console.cloud.google.com/) and enable the **Gmail API**.
2. Configure the Google Auth Platform consent screen for your app. During development, use **Testing** and add your Google account as a test user. Add `https://www.googleapis.com/auth/gmail.readonly` to the app's data-access scopes. This is a restricted scope; public distribution requires Google's verification planning.
3. Create an OAuth client with application type **iOS**, **even for this macOS app**, as required by Google Sign-In. Register the app's bundle identifier (`sk.kulman.iMail` unless you change it in Xcode). Use your own Apple Team ID if the console requests it. A Desktop or Web OAuth client is not interchangeable with this configuration.
4. Open `Configuration/Google.local.xcconfig`. If it does not exist, duplicate `Google.local.xcconfig.example` and name the copy `Google.local.xcconfig`. Do not overwrite an existing configured file. Fill in both identifiers:

   ```xcconfig
   GOOGLE_CLIENT_ID = 123-example.apps.googleusercontent.com
   GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.123-example
   ```

   Use your actual client ID and its dot-reversed value (the console's **iOS URL scheme**), not these example values. The app's Info.plist and URL scheme use this configuration automatically.
5. In Xcode's **Signing & Capabilities**, select your own development team and use an Apple-issued signing certificate. Google's macOS Keychain integration requires certificate signing, not just an ad-hoc signature. Network-client and Keychain entitlements are already configured.
6. Rebuild and run, then choose **Sign in with Google** and grant read-only Gmail access.

The local xcconfig is Git-ignored. OAuth client IDs are public identifiers; do not put secrets or access/refresh tokens in it. The SDK stores credentials in Keychain; the app never writes tokens to preferences or logs. Account settings and a sign-out interface are not implemented yet. Revoke access separately in your Google account settings if needed.

External apps in Testing can have refresh tokens expire after seven days; sign in again when prompted. Workspace administrator policies can also block access.

## Structure

- `iMail/ContentView.swift`: mailbox navigation and selection
- `iMail/Views/`: conversation, composer, and shared UI
- `iMail/Models/`: sample data and observable demo mailbox
- `iMail/Gmail/`: authentication, GET-only REST client, wire/domain types, and in-memory reader state
- `Configuration/`: OAuth build configuration, URL scheme, and sandbox/Keychain entitlements
- `Tests/`: Swift Testing suites in the `iMailTests` Xcode unit-test target
- `iMail.xctestplan`: the shared unit-test plan used by the `iMail` scheme

## Unit tests

Select the **iMail** scheme and **My Mac**, then press **Command-U** (Product → Test). Individual tests and parameterized cases also appear in Xcode's **Test Navigator** (Command-6). The shared scheme uses the **iMail** test plan and builds the `iMailTests` target. No shell runners or separate Swift executables are needed.

Tests use `@testable import iMail` to exercise the actual app module. The demo suites cover filtering, read/star state, drafts, archive/trash, addressing, forwarding, validation, and simulated sends. Gmail suites cover folder queries, REST request construction, pagination, bounded fan-out, MIME/header parsing, read-only behavior, retries, cancellation, and stale results after selection/folder changes or reset. HTML tests compile the actual WebKit content rules and load fixture messages to verify styling, inline data images, disabled page scripts, and image-only resource exceptions and blocked unsupported resources/forms/navigation.

The tests are deterministic and require no OAuth configuration or real Gmail account. Network responses are supplied by fixtures. The test plan sets `IMAIL_UNIT_TESTS=1`, which disables automatic Google session restoration in the hosted app so tests cannot silently use saved account credentials. Real sign-in and UI interactions still need the manual verification below.

### Manual Gmail verification

After configuring OAuth, sign in with your test account; compare each folder and a multi-message conversation with Gmail. Archive contains received mail outside Inbox, Drafts, Junk, and Trash; Outbox stays empty until sending is implemented. Confirm unread/star state is unchanged after reading. Exercise Load More, folder switches, local search, Command-R, and an offline refresh and retry. Relaunch to verify Keychain session restoration. Confirm all write actions are disabled and the account/logout toolbar menu is absent. Compare a real HTML email with Gmail in light/dark appearances and a narrow reader pane; confirm its layout and remote images are displayed, links open externally, and scrolling and message expansion behave correctly. Email scripts, forms, external stylesheets/fonts, and automatic redirects must remain blocked. SwiftUI preview snapshots may be captured before WebKit's asynchronous content load completes; they do not establish HTML rendering correctness.

## Next

Add a persistent cache and incremental sync once the real reader is validated, then sending and mailbox mutations with separately granted scopes. The small REST client uses Foundation; a generated Gmail SDK can be introduced if the API surface grows.

CID images/attachments, offline persistence, multiple accounts, and background delivery are not implemented.

## Integration references

- [Google Sign-In setup for iOS and macOS](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google Sign-In lifecycle](https://developers.google.com/identity/sign-in/ios/sign-in)
- [Calling Google APIs with refreshed credentials](https://developers.google.com/identity/sign-in/ios/api-access)
- [Gmail thread listing](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/list)
- [Gmail message and MIME resources](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages)
- [WebKit page JavaScript controls](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript)
- [WebKit content blockers](https://developer.apple.com/documentation/webkit/wkcontentrulelist)

A distribution license has not been selected yet.
