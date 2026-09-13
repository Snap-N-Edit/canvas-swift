import Foundation
import WebKit

/// The ``SnapneditTransport`` that drives a real `WKWebView`.
///
/// Out: a `WKScriptMessageHandler` registered as `snapnedit`, which is the
/// first channel the frame probes for (`window.webkit.messageHandlers.snapnedit`).
/// In: `evaluateJavaScript("window.SnapneditNativeBridge.receive(<literal>)")`.
///
/// The message handler is deliberately NOT `self`: a `WKUserContentController`
/// retains its handlers strongly, so registering the transport would make the
/// webview own the transport that owns the webview. A tiny proxy object holds a
/// weak back-reference instead, and ``teardown()`` unregisters it.
@MainActor
public final class SnapneditWebViewTransport: NSObject, SnapneditTransport {
    private weak var webView: WKWebView?
    private let controller: WKUserContentController
    private var proxy: MessageProxy?
    private var isTornDown = false

    public var onMessage: (@MainActor (String) -> Void)?

    /// Registers the `snapnedit` handler on `webView`'s content controller.
    public init(webView: WKWebView) {
        self.webView = webView
        self.controller = webView.configuration.userContentController
        super.init()
        let proxy = MessageProxy(transport: self)
        self.proxy = proxy
        // Registering the same name twice traps, so clear any previous one.
        controller.removeScriptMessageHandler(forName: SnapneditProtocol.channelName)
        controller.add(proxy, name: SnapneditProtocol.channelName)
    }

    public func send(_ json: String) {
        guard !isTornDown, let webView else { return }
        webView.evaluateJavaScript(SnapneditJavaScript.receiveCall(json: json)) { _, _ in
            // A rejected evaluation is a dead or navigating webview; the call
            // it carried times out on its own deadline, which is a far better
            // signal than a WebKit error the host cannot act on.
        }
    }

    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        onMessage = nil
        controller.removeScriptMessageHandler(forName: SnapneditProtocol.channelName)
        proxy?.transport = nil
        proxy = nil
    }

    fileprivate func deliver(_ body: Any) {
        // The frame always posts a string; be liberal about what a future one
        // might send, so a shape change degrades to an `invalid_input` event
        // rather than silence.
        let json: String
        switch body {
        case let value as String: json = value
        case let value as NSNumber: json = value.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: body), let value = String(data: data, encoding: .utf8) else { return }
            json = value
        }
        onMessage?(json)
    }

    /// Holds the strong reference `WKUserContentController` insists on, without
    /// letting it reach back into the transport.
    @MainActor
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var transport: SnapneditWebViewTransport?
        init(transport: SnapneditWebViewTransport) { self.transport = transport }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // WebKit delivers this on the main thread, and the SDK annotates
            // the whole callback `@MainActor` — so the envelope reaches the
            // handle synchronously, in the order the frame produced it.
            transport?.deliver(message.body)
        }
    }
}
