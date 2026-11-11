import AppKit
import Testing
import WebKit
@testable import Postie

@Suite("HTML email security", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EmailHTMLTests {
    @Test("Privacy rules compile in WebKit, including every blocked scheme")
    func contentBlockerCompiles() async throws {
        let rules = try await EmailHTMLPolicy.rules()
        #expect(rules.identifier == "Postie.EmailPrivacy.v2")
    }

    @Test("Image exceptions are restricted to HTTP(S) image requests")
    func imageExceptions() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(EmailHTMLPolicy.contentRules.utf8)) as? [[String: Any]])
        let exceptions = rules.filter { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" }
        #expect(exceptions.count == 2)
        for rule in exceptions {
            let trigger = try #require(rule["trigger"] as? [String: Any])
            #expect(trigger["resource-type"] as? [String] == ["image"])
            #expect(["^http:", "^https:"].contains(trigger["url-filter"] as? String ?? ""))
        }
        #expect(EmailHTMLPolicy.csp.contains("img-src data: https: http:"))
        #expect(EmailHTMLPolicy.csp.contains("script-src 'none'"))
    }

    @Test("The renderer disables email JavaScript and persistent website storage")
    func configuration() {
        let configuration = EmailHTMLPolicy.configuration()
        #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        #expect(!configuration.websiteDataStore.isPersistent)
        #expect(configuration.userContentController.userScripts.allSatisfy { $0.isForMainFrameOnly })
    }

    @Test("Only intentional web and mail links may leave the renderer", arguments: [
        ("https://example.com/booking", true), ("http://example.com/booking", true),
        ("mailto:friend@example.com", true), ("javascript:alert(1)", false),
        ("file:///etc/passwd", false), ("data:text/html,hello", false),
        ("postie://account", false), ("tel:1234", false), ("https:relative", false),
        ("about:blank", false)
    ])
    func links(input: (String, Bool)) {
        #expect((EmailHTMLPolicy.externalLink(URL(string: input.0)) != nil) == input.1)
    }

    @Test("CSP is installed before email markup and cannot be replaced by it")
    func cspOrdering() throws {
        let html = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src *\"><p>Message</p>"
        let document = EmailHTMLPolicy.document(html, dark: false)
        let policy = try #require(document.range(of: EmailHTMLPolicy.csp))
        let email = try #require(document.range(of: html))
        #expect(policy.upperBound < email.lowerBound)
        #expect(document.contains("base-uri 'none'"))
        #expect(document.contains("form-action 'none'"))
    }

    @Test("The message only scrolls vertically on its own beyond the height cap")
    func layoutScriptHidesVerticalOverflow() {
        let script = EmailHTMLPolicy.layoutScript
        #expect(script.contains("body.scrollHeight"))
        #expect(script.contains("height > \(Int(EmailHTMLPolicy.maximumHeight)) ? 'auto' : 'hidden'"))
    }

    @Test("Actual WebKit retains table layout and inline styling, but runs no email scripts")
    func renderedHTML() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        let html = """
        <html><head><style>#booking { font-size: 22px; } td { padding: 8px; }</style></head>
        <body onload="document.body.dataset.onloadRan='yes'">
        <script>document.body.dataset.scriptRan='yes';</script>
        <h1 id="booking">Café reservation</h1>
        <table><tr><td>Friday</td><td><strong>14:30</strong></td></tr></table>
        <img id="inline" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
             onload="document.body.dataset.imageScriptRan='yes'">
        </body></html>
        """
        let height = try await page.load(html)
        #expect(height > 50)
        let result = try await page.inspect("""
        return {
            text: document.body.innerText,
            fontSize: getComputedStyle(document.getElementById('booking')).fontSize,
            tableCount: document.querySelectorAll('table').length,
            imageWidth: document.getElementById('inline').naturalWidth,
            scriptRan: document.body.dataset.scriptRan || '',
            onloadRan: document.body.dataset.onloadRan || '',
            imageScriptRan: document.body.dataset.imageScriptRan || ''
        };
        """)
        #expect((result["text"] as? String)?.contains("Café reservation") == true)
        #expect(result["fontSize"] as? String == "22px")
        #expect(result["tableCount"] as? Int == 1)
        #expect(result["imageWidth"] as? Int == 1)
        #expect(result["scriptRan"] as? String == "")
        #expect(result["onloadRan"] as? String == "")
        #expect(result["imageScriptRan"] as? String == "")
        #expect(page.view.url?.absoluteString == "about:blank")
    }

    @Test("Simple HTML wraps at a reading measure but stays within a narrow pane")
    func readableWidth() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        page.view.frame.size.width = 1200
        _ = try await page.load("<div>" + String(repeating: "A readable paragraph of ordinary correspondence. ", count: 40) + "</div>")
        let wide = try await page.inspect("return { width: document.body.getBoundingClientRect().width };")
        let width = try #require(wide["width"] as? Double)
        #expect(width < 800)
        #expect(width > 300)

        page.view.frame.size.width = 320
        let narrow = try await page.inspect("return { width: document.body.getBoundingClientRect().width };")
        #expect(try #require(narrow["width"] as? Double) <= 320)
    }

    @Test("Tables and authored widths keep their layout in wide panes", arguments: [
        "<table style='width:100%'><tr><td>Wide receipt</td></tr></table>",
        "<div style='width:100%'>Authored layout</div>",
        "<style>.layout { width:100%; }</style><div class='layout'>Styled layout</div>",
        "<pre>Wide code</pre>"
    ])
    func authoredReadingWidth(html: String) async throws {
        let page = BrowserFixture()
        defer { page.close() }
        page.view.frame.size.width = 1200
        _ = try await page.load(html)
        let result = try await page.inspect("return { width: document.body.getBoundingClientRect().width };")
        #expect(try #require(result["width"] as? Double) == 1200)
    }

    @Test("Reading size scales nested and fixed-size text once, preserves images and quotes, and resets exactly")
    func readingTextSize() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        _ = try await page.load("""
        <div id="parent" style="font-size: 20px; line-height: 24px">
            Parent <span id="child" style="font-size: 0.5em">Nested text</span>
        </div>
        <img id="image" width="40" height="30"
             src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        <div class="gmail_quote">Earlier text</div>
        """)
        _ = try await page.inspect("document.querySelector('[data-quote-toggle]').click(); return {};")
        let inspect = """
        return {
            parent: getComputedStyle(document.getElementById('parent')).fontSize,
            child: getComputedStyle(document.getElementById('child')).fontSize,
            lineHeight: getComputedStyle(document.getElementById('parent')).lineHeight,
            imageWidth: document.getElementById('image').getBoundingClientRect().width,
            expanded: document.querySelector('[data-quote-toggle]').getAttribute('aria-expanded'),
            inlineSize: document.getElementById('child').style.getPropertyValue('font-size')
        };
        """
        let original = try await page.inspect(inspect)
        page.coordinator.setTextScale(2, in: page.view)
        let bigger = try await page.inspect(inspect)
        #expect(bigger["parent"] as? String == "40px")
        #expect(bigger["child"] as? String == "20px")
        #expect(bigger["lineHeight"] as? String == "48px")
        #expect(bigger["imageWidth"] as? Int == 40)
        #expect(bigger["expanded"] as? String == "true")

        page.coordinator.setTextScale(1.5, in: page.view)
        let smaller = try await page.inspect(inspect)
        #expect(smaller["child"] as? String == "15px") // Not compounded from the previous size.

        page.coordinator.setTextScale(1, in: page.view)
        let reset = try await page.inspect(inspect)
        #expect(reset["parent"] as? String == original["parent"] as? String)
        #expect(reset["child"] as? String == original["child"] as? String)
        #expect(reset["inlineSize"] as? String == original["inlineSize"] as? String)
        #expect(reset["expanded"] as? String == "true")
    }

    @Test("A new email opens at the saved reading size and reports its enlarged height")
    func initialReadingTextSize() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        page.coordinator.setTextScale(2, in: page.view)
        let height = try await page.load("<div style='font-size:20px;line-height:24px'>Hello</div>")
        let result = try await page.inspect("""
        return {
            font: getComputedStyle(document.querySelector('div')).fontSize,
            height: document.body.getBoundingClientRect().height
        };
        """)
        #expect(result["font"] as? String == "40px")
        #expect(result["height"] as? Int == 48)
        #expect(height >= 48)
    }

    @Test("Quoted history is collapsed behind a button that expands it", arguments: [
        "<div>Thanks!</div><div class=\"gmail_quote\"><div>On Monday, Ann wrote:</div><blockquote>Earlier text</blockquote></div>",
        "<div>Thanks!</div><blockquote type=\"cite\"><div>On Monday, Ann wrote:</div>Earlier text</blockquote>",
        "<div>Thanks!</div><div class=\"yahoo_quoted\">On Monday, Ann wrote: Earlier text</div>"
    ])
    func quotedHistoryCollapses(html: String) async throws {
        let page = BrowserFixture()
        defer { page.close() }
        _ = try await page.load(html)
        let state = """
        const toggle = document.querySelector('[data-quote-toggle]');
        return {
            hasToggle: toggle !== null,
            expanded: toggle?.getAttribute('aria-expanded') ?? '',
            text: document.body.innerText
        };
        """
        let collapsed = try await page.inspect(state)
        #expect(collapsed["hasToggle"] as? Bool == true)
        #expect(collapsed["expanded"] as? String == "false")
        #expect((collapsed["text"] as? String)?.contains("Thanks!") == true)
        #expect((collapsed["text"] as? String)?.contains("Earlier text") == false)

        _ = try await page.inspect("document.querySelector('[data-quote-toggle]').click(); return {};")
        let expanded = try await page.inspect(state)
        #expect(expanded["expanded"] as? String == "true")
        #expect((expanded["text"] as? String)?.contains("Earlier text") == true)

        _ = try await page.inspect("document.querySelector('[data-quote-toggle]').click(); return {};")
        let again = try await page.inspect(state)
        #expect((again["text"] as? String)?.contains("Earlier text") == false)
    }

    @Test("Messages without their own text before the quote are shown as they are", arguments: [
        "<div class=\"gmail_quote\">Earlier text</div>",
        "<p>No quote at all</p>"
    ])
    func quotedHistoryStaysVisible(html: String) async throws {
        let page = BrowserFixture()
        defer { page.close() }
        _ = try await page.load(html)
        let result = try await page.inspect("""
        return {
            hasToggle: document.querySelector('[data-quote-toggle]') !== null,
            text: document.body.innerText
        };
        """)
        #expect(result["hasToggle"] as? Bool == false)
        #expect(result["text"] as? String != "")
    }

    @Test("CSP blocks resource requests, frames, and forms before the scheme handler is reached")
    func resourcesAndForms() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        _ = try await page.load("""
        <base href="mail-test://remote/">
        <link rel="stylesheet" href="mail-test://remote/style.css">
        <style>@import url('mail-test://remote/import.css');
        #background { background-image: url('mail-test://remote/background.png'); height: 20px; }
        @font-face { font-family: Remote; src: url('mail-test://remote/font.woff'); }
        #background { font-family: Remote; }</style>
        <p>Original message</p><div id="background">Text</div>
        <img id="tracker" src="mail-test://remote/pixel.png">
        <iframe src="mail-test://remote/frame"></iframe>
        <object data="mail-test://remote/object"></object>
        <form action="mail-test://remote/submit"><input name="secret" value="private"></form>
        """)
        let result = try await page.inspect("""
        document.forms[0].submit();
        return {
            text: document.body.innerText,
            imageWidth: document.getElementById('tracker').naturalWidth,
            baseURI: document.baseURI
        };
        """)
        #expect(page.resources.started == 0)
        #expect(page.openedLinks.isEmpty)
        #expect(result["imageWidth"] as? Int == 0)
        #expect(result["baseURI"] as? String == "about:blank")
        #expect((result["text"] as? String)?.contains("Original message") == true)
    }

    @Test("Automatic refresh cannot navigate or open the browser")
    func automaticNavigation() async throws {
        let page = BrowserFixture()
        defer { page.close() }
        _ = try await page.load("""
        <meta http-equiv="refresh" content="0;url=mail-test://remote/redirect">
        <p>Original message</p>
        """)
        #expect(page.view.url?.absoluteString == "about:blank")
        #expect(page.resources.started == 0)
        #expect(page.openedLinks.isEmpty)
    }
}

@MainActor
private final class BrowserFixture {
    let view: EmailWebView
    let coordinator = EmailHTMLWebView.Coordinator()
    let resources = ResourceProbe()
    private let heights: AsyncThrowingStream<CGFloat, Error>
    private let events: AsyncThrowingStream<CGFloat, Error>.Continuation
    private(set) var openedLinks: [URL] = []

    init() {
        (heights, events) = AsyncThrowingStream.makeStream(of: CGFloat.self)
        let configuration = EmailHTMLPolicy.configuration()
        configuration.setURLSchemeHandler(resources, forURLScheme: "mail-test")
        view = EmailWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 140), configuration: configuration)
        view.navigationDelegate = coordinator
        configuration.userContentController.add(coordinator, contentWorld: EmailHTMLPolicy.world, name: EmailHTMLPolicy.heightHandler)
        coordinator.heightChanged = { [events] in events.yield($0) }
        coordinator.failed = { [events] in events.finish(throwing: BrowserFailure.rendering) }
        coordinator.openLink = { [weak self] in self?.openedLinks.append($0) }
    }

    func load(_ html: String) async throws -> CGFloat {
        coordinator.load(html: html, dark: false, in: view)
        var iterator = heights.makeAsyncIterator()
        guard let height = try await iterator.next() else { throw CancellationError() }
        // Wait for resources and page load, not an arbitrary sleep.
        _ = try await view.callAsyncJavaScript("""
        await new Promise(resolve => {
            if (document.readyState === 'complete') resolve();
            else window.addEventListener('load', resolve, { once: true });
        });
        return true;
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        return height
    }

    func inspect(_ script: String) async throws -> [String: Any] {
        let value = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        return try #require(value as? [String: Any])
    }

    func close() {
        EmailHTMLWebView.dismantleNSView(view, coordinator: coordinator)
        events.finish()
    }

    private enum BrowserFailure: Error { case rendering }
}

@MainActor
private final class ResourceProbe: NSObject, WKURLSchemeHandler {
    private(set) var started = 0

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        started += 1
        let url = urlSchemeTask.request.url!
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: "utf-8"))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
