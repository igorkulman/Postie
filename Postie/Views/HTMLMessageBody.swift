import SwiftUI
import WebKit

struct HTMLMessageBody: View {
    let html: String
    let plainText: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var height: CGFloat = 140
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if failed {
                Text(plainText)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                Text("Unable to display HTML. Showing plain text.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                EmailHTMLWebView(
                    html: html, dark: colorScheme == .dark,
                    heightChanged: { height = $0 }, failed: { failed = true },
                    openLink: { openURL($0) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: html) { _, _ in failed = false }
    }
}

// Defense in depth: CSP, a compiled content blocker, disabled page JavaScript,
// ephemeral storage, and a navigation delegate. Only HTTP(S) image resources are exempted;
// no email is loaded before the blocker is installed.
enum EmailHTMLPolicy {
    static let world = WKContentWorld.world(name: "Postie.EmailLayout")
    static let heightHandler = "emailHeight"
    // Real threads with long quoted histories reach tens of thousands of points.
    static let maximumHeight: CGFloat = 500_000
    // WebKit's content-blocker regex dialect does not support alternation (|).
    static let contentRules = #"""
    [
        {"trigger":{"url-filter":"^http:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^https:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^ws:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^wss:"},"action":{"type":"block"}},
        {"trigger":{"url-filter":"^http:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},
        {"trigger":{"url-filter":"^https:","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}
    ]
    """#
    static let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'"
    private static var ruleTask: Task<WKContentRuleList, Error>?
    private enum Failure: Error { case blockerUnavailable }

    static func rules() async throws -> WKContentRuleList {
        if let ruleTask { return try await ruleTask.value }
        let task = Task { @MainActor in
            guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "Postie.EmailPrivacy.v2", encodedContentRuleList: contentRules
            ) else { throw Failure.blockerUnavailable }
            return rules
        }
        ruleTask = task
        do {
            return try await task.value
        } catch {
            ruleTask = nil
            throw error
        }
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: layoutScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
        ))
        return configuration
    }

    static func document(_ html: String, dark: Bool) -> String {
        // The restrictive CSP precedes all untrusted markup; later policies cannot relax it.
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        body { display: flow-root; margin: 0; padding: 0; font: 13px -apple-system, sans-serif;
               line-height: 1.5; color: CanvasText; background-color: Canvas; overflow-wrap: anywhere; }
        img, table { max-width: 100%; }
        img { height: auto; }
        pre { white-space: pre-wrap; }
        a { color: LinkText; }
        </style></head><body>\(html)</body></html>
        """
    }

    static func externalLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url.path.isEmpty ? nil : url
        default: return nil
        }
    }

    static func javaScriptString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "''"
    }

    // App-owned code runs in an isolated content world, not the email's page world.
    static let layoutScript = """
    (() => {
        let lastHeight = -1;
        const root = document.documentElement;
        const report = () => {
            // The body's scrollHeight also counts content overflowing it, which its own rect misses.
            // Unlike the root's, it never grows to fill the viewport, so the view can still shrink.
            const body = document.body;
            const height = Math.ceil(Math.max(body.getBoundingClientRect().height, body.scrollHeight));
            // The web view is sized to its content, so the conversation scrolls, not the message.
            // Only a body taller than the cap keeps its own vertical scrolling.
            root.style.overflowY = height > \(Int(maximumHeight)) ? 'auto' : 'hidden';
            if (height !== lastHeight) {
                lastHeight = height;
                window.webkit.messageHandlers.emailHeight.postMessage(height);
            }
        };
        // Quoted history is collapsed behind a "..." button, as other mail clients do. Only the first,
        // outermost quote is handled (nested ones stay inside it), and only when the message has
        // content of its own before it, so a message that is only a quote is shown as is.
        const quote = document.querySelector('div.gmail_quote, blockquote[type=cite], div.yahoo_quoted');
        if (quote) {
            const before = document.createRange();
            before.setStart(document.body, 0);
            before.setEndBefore(quote);
            if (before.toString().trim().length > 0 || before.cloneContents().querySelector('img')) {
                const previousDisplay = quote.style.display;
                const toggle = document.createElement('button');
                toggle.type = 'button';
                toggle.dataset.quoteToggle = '';
                toggle.textContent = '···';
                toggle.title = \(EmailHTMLPolicy.javaScriptString(String(localized: "Show quoted text", comment: "Tooltip of the button that expands the quoted history of an email")));
                toggle.setAttribute('aria-label', toggle.title);
                toggle.setAttribute('aria-expanded', 'false');
                toggle.style.cssText = 'display: block; margin: 8px 0; padding: 0 8px; border: 0; border-radius: 6px; '
                    + 'font: inherit; line-height: 1.2; color: GrayText; cursor: pointer; '
                    + 'background: color-mix(in srgb, CanvasText 12%, transparent);';
                quote.style.display = 'none';
                quote.parentNode.insertBefore(toggle, quote);
                toggle.addEventListener('click', () => {
                    const expanded = toggle.getAttribute('aria-expanded') !== 'true';
                    toggle.setAttribute('aria-expanded', String(expanded));
                    toggle.title = expanded
                        ? \(EmailHTMLPolicy.javaScriptString(String(localized: "Hide quoted text", comment: "Tooltip of the button that collapses the quoted history of an email")))
                        : \(EmailHTMLPolicy.javaScriptString(String(localized: "Show quoted text", comment: "Tooltip of the button that expands the quoted history of an email")));
                    toggle.setAttribute('aria-label', toggle.title);
                    quote.style.display = expanded ? previousDisplay : 'none';
                });
            }
        }
        new ResizeObserver(report).observe(document.body);
        window.addEventListener('resize', report);
        window.addEventListener('load', report);
        report();
    })();
    """
}

struct EmailHTMLWebView: NSViewRepresentable {
    let html: String
    let dark: Bool
    let heightChanged: (CGFloat) -> Void
    let failed: () -> Void
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EmailWebView {
        let view = EmailWebView(frame: .zero, configuration: EmailHTMLPolicy.configuration())
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel(String(localized: "HTML email body", comment: "Accessibility label for the web view showing a formatted email"))
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.configuration.userContentController.add(
            context.coordinator, contentWorld: EmailHTMLPolicy.world, name: EmailHTMLPolicy.heightHandler
        )
        return view
    }

    func updateNSView(_ view: EmailWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.heightChanged = heightChanged
        coordinator.failed = failed
        coordinator.openLink = openLink
        // Compare the inputs: building the document string for a large email on every update just to compare it is wasteful.
        guard html != coordinator.html || dark != coordinator.dark else { return }
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.underPageBackgroundColor = .textBackgroundColor
        coordinator.load(html: html, dark: dark, in: view)
    }

    static func dismantleNSView(_ view: EmailWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.heightChanged = nil
        coordinator.failed = nil
        coordinator.openLink = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private(set) var html: String?
        private(set) var dark: Bool?
        var loadTask: Task<Void, Never>?
        var heightChanged: ((CGFloat) -> Void)?
        var failed: (() -> Void)?
        var openLink: ((URL) -> Void)?
        private var awaitingInitialDocument = false

        func load(html: String, dark: Bool, in view: EmailWebView) {
            self.html = html
            self.dark = dark
            let document = EmailHTMLPolicy.document(html, dark: dark)
            loadTask?.cancel()
            view.stopLoading()
            loadTask = Task { @MainActor [weak self, weak view] in
                do {
                    let rules = try await EmailHTMLPolicy.rules()
                    try Task.checkCancellation()
                    guard let self, let view, self.html == html, self.dark == dark else { return }
                    view.configuration.userContentController.removeAllContentRuleLists()
                    view.configuration.userContentController.add(rules)
                    self.awaitingInitialDocument = true
                    view.loadHTMLString(document, baseURL: nil)
                } catch is CancellationError {
                    // A collapsed/replaced message must not update the reader.
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.failed?() // Fail closed: never load without the blocker.
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.name == EmailHTMLPolicy.heightHandler,
                  let number = message.body as? NSNumber else { return }
            let height = CGFloat(number.doubleValue)
            guard height.isFinite, height >= 0 else { return }
            (message.webView as? EmailWebView)?.scrollsVertically = height > EmailHTMLPolicy.maximumHeight
            heightChanged?(min(max(24, height), EmailHTMLPolicy.maximumHeight))
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if awaitingInitialDocument, navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.request.url?.absoluteString == "about:blank" {
                awaitingInitialDocument = false
                decisionHandler(.allow)
                return
            }
            // Never browse inside an email, submit forms, follow refreshes, or open custom schemes.
            if navigationAction.navigationType == .linkActivated,
               navigationAction.sourceFrame.isMainFrame,
               let url = EmailHTMLPolicy.externalLink(navigationAction.request.url) {
                openLink?(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failed?() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { failed?() }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed?() }
    }
}

final class EmailWebView: WKWebView {
    var scrollsVertically = false

    override func scrollWheel(with event: NSEvent) {
        // Ordinary bodies fit their content; vertical scrolling belongs to the conversation.
        // Retain inner scrolling for unusually long bodies or wide, fixed-width email tables.
        if !scrollsVertically, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

#if DEBUG
private let reservationPreviewHTML = """
<html><head><style>
    .reservation { max-width: 560px; margin: 0 auto; font: 14px -apple-system, sans-serif; }
    .reservation h1 { font-size: 24px; margin-bottom: 4px; }
    .reservation td { padding: 8px 0; border-bottom: 1px solid #8885; }
</style></head><body><div class="reservation">
<h1>Your reservation is confirmed</h1><p>Hi Alex, we're looking forward to seeing you.</p>
<table width="100%"><tr><td>Service</td><td><strong>Haircut</strong></td></tr>
<tr><td>When</td><td>Friday, 2 October · 14:30</td></tr>
<tr><td>Where</td><td>24 Market Street</td></tr></table>
<p>Please arrive five minutes before your appointment.</p>
<p><a href="https://example.com/reservations">Manage reservation</a></p>
<img src="https://example.com/logo.png" alt="Salon logo" width="120">
</div></body></html>
"""

private func reservationPreview() -> ThreadDetailView {
    ThreadDetailView(thread: MailThread(
        id: "reservation",
        subject: "Reservation confirmation",
        messages: [MailMessage(id: "reservation-message", senderName: "The Salon", senderEmail: "booking@example.com",
            recipient: "alex@example.com", date: Date(timeIntervalSince1970: 1_791_000_000),
            body: "Your reservation is confirmed. Haircut, Friday at 14:30, 24 Market Street.",
            htmlBody: reservationPreviewHTML)], mailbox: .inbox
    ), canToggleStar: false, toggleStar: {})
}

#Preview("HTML reservation") {
    reservationPreview().frame(width: 620, height: 640)
}

#Preview("HTML reservation · Compact dark") {
    reservationPreview().frame(width: 380, height: 640).preferredColorScheme(.dark)
}
#endif
