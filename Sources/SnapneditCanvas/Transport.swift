import Foundation

/// The two I/O functions a host has to provide, and the only thing that
/// differs between the postMessage and native worlds.
///
/// ``SnapneditEditorHandle`` is written entirely against this, which is what
/// lets the whole protocol layer be tested with a fake in place of a
/// WKWebView. The shipped implementation is ``SnapneditWebViewTransport``.
@MainActor
public protocol SnapneditTransport: AnyObject {
    /// Hands the frame one complete JSON envelope.
    ///
    /// Must not throw: a dead channel is dropped, never propagated into the
    /// editor. A call whose message is lost times out on its own deadline.
    func send(_ json: String)

    /// Installed by the handle before anything is sent. Every JSON string the
    /// frame produces goes here, on the main actor.
    var onMessage: (@MainActor (String) -> Void)? { get set }

    /// Releases the channel. Idempotent, and must be safe to call from
    /// `deinit`-adjacent teardown.
    func teardown()
}
