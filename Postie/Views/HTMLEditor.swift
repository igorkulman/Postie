import SwiftUI
import WebKit

/// What the editor reports: the formatted message, its plain-text version for clients that cannot show
/// HTML, and what the person typed without any quoted original.
struct EditorContent: Equatable {
    var html: String
    var text: String
    var ownText: String

    init(html: String, text: String, ownText: String) {
        self.html = html
        self.text = text
        self.ownText = ownText
    }

    init?(_ message: [String: Any]) {
        guard let html = message["html"] as? String, let text = message["text"] as? String,
              let ownText = message["own"] as? String else { return nil }
        self.init(html: html, text: text, ownText: ownText)
    }
}

/// Which formatting applies at the cursor, for the toolbar buttons.
struct EditorFormat: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var bulletList = false
    var numberedList = false
}

/// Drives the editor from the toolbar and reads its content on demand.
@MainActor
@Observable
final class RichTextController {
    private(set) var format = EditorFormat()
    @ObservationIgnored fileprivate weak var webView: WKWebView?

    func toggleBold() { run("exec(command)", ["command": "bold"]) }
    func toggleItalic() { run("exec(command)", ["command": "italic"]) }
    func toggleUnderline() { run("exec(command)", ["command": "underline"]) }
    func toggleBulletList() { run("exec(command)", ["command": "insertUnorderedList"]) }
    func toggleNumberedList() { run("exec(command)", ["command": "insertOrderedList"]) }
    func clearFormatting() { run("exec(command)", ["command": "removeFormat"]) }

    func insertLink(_ url: URL) { run("link(url)", ["url": url.absoluteString]) }

    func focus() { run("focus()") }

    /// Puts the signature under what the person writes, above any quoted original. Nil or empty removes it.
    func setSignature(_ html: String?) async {
        _ = try? await webView?.callAsyncJavaScript(
            "return postieEditor.setSignature(html)", arguments: ["html": html ?? ""], contentWorld: RichTextPolicy.world
        )
    }

    /// The editor as it is right now, without waiting for its next change notification.
    func content() async -> EditorContent? {
        guard let webView, let result = try? await webView.callAsyncJavaScript(
            "return postieEditor.snapshot()", contentWorld: RichTextPolicy.world
        ) as? [String: Any] else { return nil }
        return EditorContent(result)
    }

    /// Turns what the person typed into an address a link can use, or nil when it is not one.
    nonisolated static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("mailto:") {
            candidate = trimmed
        } else if trimmed.contains("@") {
            candidate = "mailto:" + trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url.path.isEmpty ? nil : url
        default: return nil
        }
    }

    fileprivate func apply(_ format: EditorFormat) {
        if self.format != format { self.format = format }
    }

    private func run(_ call: String, _ arguments: [String: Any] = [:]) {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "return postieEditor." + call, arguments: arguments, contentWorld: RichTextPolicy.world
            )
        }
    }
}

/// The composer's body: a formatting bar over the editable message.
struct RichTextEditor: View {
    let html: String
    let controller: RichTextController
    let focusOnLoad: Bool
    let loaded: (EditorContent) -> Void
    let changed: (EditorContent) -> Void
    let dropFiles: ([URL]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FormattingBar(controller: controller)
            Divider()
            HTMLEditor(html: html, controller: controller, focusOnLoad: focusOnLoad,
                       loaded: loaded, changed: changed, dropFiles: dropFiles)
        }
    }
}

private struct FormattingBar: View {
    let controller: RichTextController
    @State private var addsLink = false
    @State private var address = ""

    var body: some View {
        HStack(spacing: 2) {
            button("Bold", controller.format.bold, controller.toggleBold) { Text("B").bold().offset(y: -1) }
            button("Italic", controller.format.italic, controller.toggleItalic) { Text("I").italic().offset(y: -1) }
            button("Underline", controller.format.underline, controller.toggleUnderline) { Text("U").underline().offset(y: -1) }
            separator
            button("Bulleted List", controller.format.bulletList, controller.toggleBulletList) { Image(systemName: "list.bullet") }
            button("Numbered List", controller.format.numberedList, controller.toggleNumberedList) { Image(systemName: "list.number") }
            separator
            button("Add Link", false) { address = ""; addsLink = true } label: { Image(systemName: "link") }
                .popover(isPresented: $addsLink, arrowEdge: .bottom) { linkForm }
            button("Clear Formatting", false, controller.clearFormatting) { Image(systemName: "eraser") }
            Spacer()
        }
        // The first glyph sits inside its button, so the bar starts left of the 20 pt gutter to line the glyph up with it.
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    /// Every button has the same footprint and type size, so the row lines up whatever the glyph's own shape.
    private func button<Label: View>(_ title: LocalizedStringKey, _ isOn: Bool, _ action: @escaping () -> Void,
                                     @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 24)
                .background(isOn ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : .secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var linkForm: some View {
        let url = RichTextController.linkURL(from: address)
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Web address", text: $address)
                .frame(width: 260)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { addsLink = false }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil)
            }
        }
        .padding(12)
    }

    private func add() {
        guard let url = RichTextController.linkURL(from: address) else { return }
        addsLink = false
        controller.insertLink(url)
    }
}

/// The editing surface. The message is HTML in a web view with its own page JavaScript switched off: only the
/// app's scripts, which run in an isolated world, can touch it, so quoted mail cannot run code.
struct HTMLEditor: NSViewRepresentable {
    let html: String
    let controller: RichTextController
    let focusOnLoad: Bool
    let loaded: (EditorContent) -> Void
    let changed: (EditorContent) -> Void
    let dropFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorWebView {
        let view = EditorWebView(frame: .zero, configuration: RichTextPolicy.configuration())
        let coordinator = context.coordinator
        view.navigationDelegate = coordinator
        view.underPageBackgroundColor = .textBackgroundColor
        view.setAccessibilityLabel(String(localized: "Message body"))
        view.configuration.userContentController.add(coordinator, contentWorld: RichTextPolicy.world, name: RichTextPolicy.handler)
        controller.webView = view
        update(coordinator, view)
        coordinator.load(html: html, label: String(localized: "Message body"), in: view)
        return view
    }

    // The editor owns the message once it is loaded, so a changed `html` never reloads it.
    func updateNSView(_ view: EditorWebView, context: Context) {
        update(context.coordinator, view)
    }

    private func update(_ coordinator: Coordinator, _ view: EditorWebView) {
        coordinator.controller = controller
        coordinator.focusOnLoad = focusOnLoad
        coordinator.loaded = loaded
        coordinator.changed = changed
        view.dropFiles = dropFiles
    }

    static func dismantleNSView(_ view: EditorWebView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.controller = nil
        coordinator.loaded = nil
        coordinator.changed = nil
        view.dropFiles = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var controller: RichTextController?
        var focusOnLoad = false
        var loaded: ((EditorContent) -> Void)?
        var changed: ((EditorContent) -> Void)?
        var loadTask: Task<Void, Never>?
        private var awaitingInitialDocument = false

        func load(html: String, label: String, in view: EditorWebView) {
            let document = RichTextPolicy.document(html, label: label)
            loadTask = Task { [weak self, weak view] in
                // Fail closed: never load without the content blocker.
                guard let rules = try? await EmailHTMLPolicy.rules(), !Task.isCancelled, let self, let view else { return }
                view.configuration.userContentController.add(rules)
                self.awaitingInitialDocument = true
                view.loadHTMLString(document, baseURL: nil)
            }
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.frameInfo.isMainFrame, message.name == RichTextPolicy.handler,
                      let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                switch type {
                case "ready":
                    guard let content = EditorContent(body) else { return }
                    loaded?(content)
                    if focusOnLoad { controller?.focus() }
                case "change":
                    if let content = EditorContent(body) { changed?(content) }
                case "format":
                    controller?.apply(EditorFormat(
                        bold: body["bold"] as? Bool ?? false, italic: body["italic"] as? Bool ?? false,
                        underline: body["underline"] as? Bool ?? false, bulletList: body["bulletList"] as? Bool ?? false,
                        numberedList: body["numberedList"] as? Bool ?? false
                    ))
                default: break
                }
            }
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
            // A draft is edited here, never browsed: links, forms and refreshes go nowhere.
            decisionHandler(.cancel)
        }
    }
}

/// Takes dropped files for the message's attachments; everything else is the editor's own.
final class EditorWebView: WKWebView {
    var dropFiles: (([URL]) -> Void)?

    private func files(in info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        files(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = files(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        dropFiles?(urls)
        return true
    }
}

enum RichTextPolicy {
    static let world = WKContentWorld.world(name: "Postie.Editor")
    static let handler = "editor"

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The page's own scripts stay off; the app's scripts below run regardless.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world
        ))
        return configuration
    }

    static func document(_ html: String, label: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(EmailHTMLPolicy.csp)">
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; height: 100%; }
        body { font: 14px -apple-system, sans-serif; line-height: 1.4; color: CanvasText; background-color: Canvas; }
        #editor { box-sizing: border-box; min-height: 100%; padding: 12px 20px; outline: none; overflow-wrap: anywhere; }
        #editor img, #editor table { max-width: 100%; }
        #editor a { color: LinkText; }
        #editor blockquote { margin: 0 0 0 0.8ex; border-left: 1px solid #ccc; padding-left: 1ex; }
        </style></head><body><div id="editor" contenteditable="true" spellcheck="true" role="textbox"
        aria-multiline="true" aria-label="\(HTMLText.escape(label))">\(html)</div></body></html>
        """
    }

    private static let script = #"""
    (() => {
        const handler = window.webkit.messageHandlers.editor;
        const editor = document.getElementById('editor');
        const BLOCKS = new Set(['DIV', 'P', 'UL', 'OL', 'LI', 'TR', 'TABLE', 'PRE', 'BLOCKQUOTE', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6']);
        const SKIPPED = new Set(['SCRIPT', 'STYLE', 'HEAD', 'TITLE']);
        let saved = null;
        let timer = null;

        // The plain-text version: quotes get "> ", list items get markers, links show their address.
        function plain(node) {
            if (node.nodeType === 3) return node.nodeValue.replace(/ /g, ' ');
            if (node.nodeType !== 1 || SKIPPED.has(node.tagName)) return '';
            const tag = node.tagName;
            if (tag === 'BR') return '\n';
            let out = '';
            let index = 0;
            for (const child of node.childNodes) {
                const block = child.nodeType === 1 && BLOCKS.has(child.tagName);
                let part = plain(child);
                if (child.tagName === 'LI') {
                    index += 1;
                    part = (tag === 'OL' ? index + '. ' : '• ') + part;
                }
                if (block && out && !out.endsWith('\n')) out += '\n';
                out += part;
                if (block && !out.endsWith('\n')) out += '\n';
            }
            if (tag === 'A') {
                const href = node.getAttribute('href');
                if (href && href !== out.trim() && /^(https?:|mailto:)/i.test(href)) out += ' (' + href + ')';
            }
            if (tag === 'BLOCKQUOTE') {
                out = out.replace(/\n+$/, '').split('\n').map(line => line ? '> ' + line : '>').join('\n');
            }
            return out;
        }
        const text = node => plain(node).replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '');

        function typed() {
            const copy = editor.cloneNode(true);
            copy.querySelectorAll('.gmail_quote, .gmail_signature').forEach(part => part.remove());
            return text(copy).trim();
        }
        function snapshot() { return { html: editor.innerHTML, text: text(editor), own: typed() }; }
        function report(type) { handler.postMessage(Object.assign({ type }, snapshot())); }
        function changed() {
            clearTimeout(timer);
            timer = setTimeout(() => report('change'), 100);
        }

        // Pasted and dropped markup keeps its structure, but not scripts, styles, images or attributes.
        function clean(html) {
            const doc = new DOMParser().parseFromString(html, 'text/html');
            doc.querySelectorAll('script,style,meta,link,iframe,object,embed,form,img,svg,math,title,head').forEach(n => n.remove());
            for (const element of doc.body.querySelectorAll('*')) {
                const href = element.tagName === 'A' ? element.getAttribute('href') : null;
                for (const name of element.getAttributeNames()) element.removeAttribute(name);
                if (href && /^(https?:|mailto:)/i.test(href)) element.setAttribute('href', href);
            }
            return doc.body.innerHTML;
        }

        function remember() {
            const selection = getSelection();
            if (selection.rangeCount && editor.contains(selection.anchorNode)) saved = selection.getRangeAt(0).cloneRange();
        }
        function restore() {
            editor.focus();
            if (!saved) return;
            const selection = getSelection();
            selection.removeAllRanges();
            selection.addRange(saved);
        }

        document.execCommand('defaultParagraphSeparator', false, 'div');
        document.addEventListener('selectionchange', () => {
            remember();
            handler.postMessage({
                type: 'format',
                bold: document.queryCommandState('bold'),
                italic: document.queryCommandState('italic'),
                underline: document.queryCommandState('underline'),
                bulletList: document.queryCommandState('insertUnorderedList'),
                numberedList: document.queryCommandState('insertOrderedList')
            });
        });
        editor.addEventListener('input', changed);
        editor.addEventListener('paste', event => {
            const data = event.clipboardData;
            if (!data) return;
            const html = data.getData('text/html');
            if (html) {
                event.preventDefault();
                document.execCommand('insertHTML', false, clean(html));
            } else if (!data.getData('text/plain')) {
                event.preventDefault();
            }
        });
        editor.addEventListener('dragover', event => event.preventDefault());
        editor.addEventListener('drop', event => {
            event.preventDefault();
            const html = event.dataTransfer && event.dataTransfer.getData('text/html');
            if (html) document.execCommand('insertHTML', false, clean(html));
        });
        editor.addEventListener('keydown', event => {
            if (!event.metaKey || event.altKey || event.ctrlKey || event.shiftKey) return;
            const command = { b: 'bold', i: 'italic', u: 'underline' }[event.key.toLowerCase()];
            if (!command) return;
            event.preventDefault();
            document.execCommand(command);
            changed();
        });

        window.postieEditor = {
            exec(command) {
                restore();
                document.execCommand(command, false, null);
                changed();
            },
            link(url) {
                restore();
                if (getSelection().isCollapsed) {
                    const anchor = document.createElement('a');
                    anchor.href = url;
                    anchor.textContent = url;
                    document.execCommand('insertHTML', false, anchor.outerHTML);
                } else {
                    document.execCommand('createLink', false, url);
                }
                changed();
            },
            // Gmail's markup for a signature, kept apart from what the person types. The signature is shown exactly as Gmail has it.
            setSignature(html) {
                let block = editor.querySelector('.gmail_signature');
                if (!html) {
                    if (block) block.remove();
                    changed();
                    return;
                }
                if (!block) {
                    block = document.createElement('div');
                    block.className = 'gmail_signature';
                    block.setAttribute('data-smartmail', 'gmail_signature');
                    const quote = editor.querySelector('.gmail_quote');
                    if (quote) quote.parentNode.insertBefore(block, quote); else editor.appendChild(block);
                }
                block.innerHTML = '<br>' + html;
                // Something to type on above the signature.
                if (block.previousSibling === null) {
                    const line = document.createElement('div');
                    line.appendChild(document.createElement('br'));
                    editor.insertBefore(line, block);
                    if (document.activeElement === editor && !typed()) this.focus();
                }
                changed();
            },
            // The cursor goes to the start, above any quoted original.
            focus() {
                editor.focus();
                let node = editor;
                while (node.firstChild && node.firstChild.nodeType === 1 && node.firstChild.tagName !== 'BR') node = node.firstChild;
                const range = document.createRange();
                range.setStart(node, 0);
                range.collapse(true);
                const selection = getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
            },
            snapshot
        };
        report('ready');
    })();
    """#
}

#Preview("Formatting bar") {
    // Between a header row and the body text, which share the 20 pt gutter the icons should line up with.
    VStack(alignment: .leading, spacing: 0) {
        Text("Subject").foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 7)
        Divider()
        FormattingBar(controller: RichTextController())
        Divider()
        FormattingBar(controller: {
            let controller = RichTextController()
            controller.apply(EditorFormat(bold: true, underline: true, bulletList: true))
            return controller
        }())
        Divider()
        Text("Hi you").padding(.horizontal, 20).padding(.vertical, 12)
    }
    .frame(width: 420)
}
