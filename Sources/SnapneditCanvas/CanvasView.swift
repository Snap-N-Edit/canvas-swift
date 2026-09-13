import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
/// `UIView` on iOS, `NSView` on macOS.
public typealias SnapneditPlatformView = UIView
#elseif canImport(AppKit)
import AppKit
/// `UIView` on iOS, `NSView` on macOS.
public typealias SnapneditPlatformView = NSView
#endif

/// The editor, as a view you can drop into an AppKit or UIKit hierarchy.
///
/// It owns a `WKWebView` pointed at
/// `<baseURL>/embed?transport=native&origin=native:<app-id>&key=…`, installs
/// the `snapnedit` script-message handler the frame looks for, and exposes
/// ``handle`` — which queues anything you call before the editor reports
/// `ready`.
///
/// ```swift
/// let canvas = try SnapneditCanvasView(configuration: config)
/// view.addSubview(canvas)
/// Task {
///     try await canvas.handle.loadImage(photo)
///     let result = try await canvas.handle.export(.png)
/// }
/// ```
///
/// Call ``SnapneditEditorHandle/destroy()`` when the screen goes away:
/// `WKUserContentController` retains its message handlers, so an editor that
/// is merely released keeps its webview alive.
@MainActor
public final class SnapneditCanvasView: SnapneditPlatformView {
    /// The live webview. Exposed for inspection (`isLoading`, a custom
    /// `navigationDelegate`, snapshotting) — not for navigating elsewhere.
    public let webView: WKWebView

    /// The editor. Safe to use immediately: calls are queued until `ready`.
    public let handle: SnapneditEditorHandle

    /// The configuration this view was built from.
    public let configuration: SnapneditCanvasConfiguration

    private let transport: SnapneditWebViewTransport

    /// Builds the view and starts loading the frame.
    ///
    /// - Throws: ``SnapneditError`` with ``SnapneditErrorCode/invalidInput``
    ///   when the native app id is malformed — the frame would refuse to boot
    ///   and install no bridge, so failing here turns a blank webview into a
    ///   real error at the call site.
    public convenience init(configuration: SnapneditCanvasConfiguration) throws {
        try self.init(configuration: configuration, webViewConfiguration: WKWebViewConfiguration())
    }

    /// As ``init(configuration:)``, but over a `WKWebViewConfiguration` you
    /// supply — a shared process pool, a custom data store, a content rule
    /// list. The `snapnedit` message handler is added to its user content
    /// controller.
    public init(configuration: SnapneditCanvasConfiguration, webViewConfiguration: WKWebViewConfiguration) throws {
        let url = try configuration.frameURL()
        self.configuration = configuration
        // The editor is a full-bleed canvas app: inline media and no user
        // gesture requirement, or video/animation previews will not play.
        #if canImport(UIKit)
        webViewConfiguration.allowsInlineMediaPlayback = true
        webViewConfiguration.mediaTypesRequiringUserActionForPlayback = []
        #endif
        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        self.webView = webView
        let transport = SnapneditWebViewTransport(webView: webView)
        self.transport = transport
        self.handle = SnapneditEditorHandle(transport: transport, timeouts: configuration.timeouts)
        super.init(frame: .zero)

        #if canImport(UIKit)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyBootstrap()
        webView.load(URLRequest(url: url))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapneditCanvasView must be created with init(configuration:)")
    }

    /// Theme and features are not URL parameters — they arrive as ordinary
    /// calls, queued behind the ready gate, so they land the instant the
    /// editor mounts and can be changed again at any time.
    private func applyBootstrap() {
        let handle = self.handle
        if let theme = configuration.theme {
            Task { try? await handle.setTheme(theme) }
        }
        if let features = configuration.features {
            Task { try? await handle.setFeatures(features) }
        }
    }

    /// Reloads the frame from scratch — a fresh editor, a fresh session token.
    ///
    /// Only useful after a boot failure you have fixed (a rotated key, a
    /// restored network). The existing ``handle`` is already terminal at that
    /// point, so build a new view instead when you need a working editor.
    public func reload() throws {
        webView.load(URLRequest(url: try configuration.frameURL()))
    }

    deinit {
        // `handle.destroy()` is main-actor work and `deinit` is not, so hop.
        // Hosts should call `destroy()` themselves — see the type's note — but
        // this keeps a forgotten one from leaking the whole webview.
        let handle = self.handle
        Task { @MainActor in handle.destroy() }
    }
}
