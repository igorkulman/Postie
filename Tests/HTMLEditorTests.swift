import Foundation
import Testing
import WebKit
@testable import Postie

/// Loads the editor's real page in a real web view, as the composer does.
@MainActor
private final class EditorHarness: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: EditorWebView
    private(set) var messages: [[String: Any]] = []
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init(html: String) {
        webView = EditorWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: RichTextPolicy.configuration())
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, contentWorld: RichTextPolicy.world, name: RichTextPolicy.handler)
        webView.loadHTMLString(RichTextPolicy.document(html, label: "Message body"), baseURL: nil)
    }

    func waitUntilReady() async {
        if messages.contains(where: { $0["type"] as? String == "ready" }) { return }
        await withCheckedContinuation { readyContinuation = $0 }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            messages.append(body)
            if body["type"] as? String == "ready" { readyContinuation?.resume(); readyContinuation = nil }
        }
    }

    func call(_ expression: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript("return " + expression, arguments: arguments, contentWorld: RichTextPolicy.world)
    }

    func snapshot() async throws -> EditorContent {
        let value = try await call("postieEditor.snapshot()") as? [String: Any]
        return try #require(value.flatMap(EditorContent.init))
    }
}

@Suite("HTML editor", .timeLimit(.minutes(1)))
@MainActor
struct HTMLEditorTests {
    @Test("The editor starts with the given markup although page scripts are off")
    func loads() async throws {
        let harness = EditorHarness(html: "<div>Hello <b>there</b></div>")
        await harness.waitUntilReady()
        let content = try await harness.snapshot()
        #expect(content.html == "<div>Hello <b>there</b></div>")
        #expect(content.text == "Hello there")
        #expect(content.ownText == "Hello there")
        // Scripts in the page itself do not run, only the app's.
        let pageScript = try await harness.webView.evaluateJavaScript("typeof window.postieEditor")
        #expect(pageScript as? String == "undefined")
    }

    @Test("Quoted text is plain text with markers and does not count as typed")
    func quote() async throws {
        let quote = HTMLText.emptyLine + "<div class=\"gmail_quote\"><div class=\"gmail_attr\">On Monday, A wrote:<br></div>"
            + "<blockquote class=\"gmail_quote\">Line one<br>Line two<ul><li>Item</li></ul>"
            + "<a href=\"https://example.com\">site</a></blockquote></div>"
        let harness = EditorHarness(html: quote)
        await harness.waitUntilReady()
        let content = try await harness.snapshot()
        #expect(content.ownText.isEmpty)
        #expect(content.text.contains("On Monday, A wrote:\n> Line one\n> Line two\n> \u{2022} Item"))
        #expect(content.text.contains("site (https://example.com)"))
    }

    @Test("Formatting commands change the markup")
    func formatting() async throws {
        let harness = EditorHarness(html: "<div>Hello</div>")
        await harness.waitUntilReady()
        _ = try await harness.webView.evaluateJavaScript(
            "document.getElementById('editor').focus(); document.execCommand('selectAll')", contentWorld: RichTextPolicy.world
        )
        _ = try await harness.call("postieEditor.exec(command)", ["command": "bold"])
        _ = try await harness.call("postieEditor.exec(command)", ["command": "insertUnorderedList"])
        var html = try await harness.snapshot().html
        #expect(html.contains("<b>Hello</b>") || html.contains("<strong>Hello</strong>"))
        #expect(html.contains("<ul>"))
        _ = try await harness.call("postieEditor.link(url)", ["url": "https://example.com"])
        html = try await harness.snapshot().html
        #expect(html.contains("href=\"https://example.com\""))
    }

    @Test("Edits are reported after a short pause")
    func reportsChanges() async throws {
        let harness = EditorHarness(html: "")
        await harness.waitUntilReady()
        _ = try await harness.webView.evaluateJavaScript(
            "const e = document.getElementById('editor'); e.focus(); document.execCommand('insertText', false, 'Typed'); e.dispatchEvent(new Event('input'))",
            contentWorld: RichTextPolicy.world
        )
        try await Task.sleep(for: .milliseconds(400))
        let change = harness.messages.last { $0["type"] as? String == "change" }
        #expect(change?["own"] as? String == "Typed")
    }

    @Test("A signature goes under the typed text and above the quote, and is not counted as typed")
    func signature() async throws {
        let quote = HTMLText.emptyLine + "<div class=\"gmail_quote\"><blockquote>Original</blockquote></div>"
        let harness = EditorHarness(html: quote)
        await harness.waitUntilReady()
        _ = try await harness.call("postieEditor.setSignature(html)", ["html": "Alex<br>Postie"])
        let content = try await harness.snapshot()
        let signature = try #require(content.html.range(of: "class=\"gmail_signature\""))
        let original = try #require(content.html.range(of: "class=\"gmail_quote\""))
        #expect(signature.lowerBound < original.lowerBound)
        #expect(content.text.contains("\nAlex\nPostie"))
        #expect(content.ownText.isEmpty)

        _ = try await harness.call("postieEditor.setSignature(html)", ["html": "New"])
        let replaced = try await harness.snapshot()
        #expect(replaced.html.components(separatedBy: "class=\"gmail_signature\"").count == 2)
        #expect(replaced.text.contains("\nNew") && !replaced.text.contains("Alex"))

        _ = try await harness.call("postieEditor.setSignature(html)", ["html": ""])
        #expect(try await harness.snapshot().html.contains("gmail_signature") == false)
    }

    @Test("On a new message the signature leaves a line to type on above it")
    func signatureOnNewMessage() async throws {
        let harness = EditorHarness(html: "")
        await harness.waitUntilReady()
        _ = try await harness.call("postieEditor.setSignature(html)", ["html": "Alex"])
        let html = try await harness.snapshot().html
        #expect(html.hasPrefix("<div><br></div><div class=\"gmail_signature\""))
    }
}
