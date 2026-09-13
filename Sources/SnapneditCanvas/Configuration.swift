import Foundation

/// How long a call may take before the wrapper gives up on it with
/// ``SnapneditErrorCode/timeout``.
///
/// The defaults are the reference loader's: 30s for an ordinary call, 180s for
/// the ones `protocol.json` flags `longRunning` (`loadImage`, `addImage`,
/// `export`, `exportTo`, `run`), 60s for the boot itself.
public struct SnapneditTimeouts: Hashable, Sendable {
    /// Ordinary calls.
    public var call: TimeInterval
    /// Calls ``SnapneditMethod/longRunning`` — an AI job, a large export.
    public var longRunningCall: TimeInterval
    /// How long the frame has to emit `ready` before the boot is failed.
    public var ready: TimeInterval

    public init(call: TimeInterval = 30, longRunningCall: TimeInterval = 180, ready: TimeInterval = 60) {
        self.call = call
        self.longRunningCall = longRunningCall
        self.ready = ready
    }

    public static let `default` = SnapneditTimeouts()

    /// The deadline for one method.
    public func deadline(for method: SnapneditMethod) -> TimeInterval {
        method.isLongRunning ? longRunningCall : call
    }
}

/// How the embed session authenticates.
public enum SnapneditCredential: Hashable, Sendable {
    /// A `pk_` publishable key plus the `native:<app-id>` it is allowlisted
    /// for (dashboard → API keys → Allowed origins). The key is public in a
    /// native app exactly as it is on the web; the app id list is not an
    /// authentication boundary, it stops casual reuse and gives you a
    /// per-surface off switch.
    case publishableKey(String, appId: String)

    /// A token your backend minted with `POST /embed/tokens`. Short-lived,
    /// skips the app-id allowlist, and lets you set per-end-user credit caps
    /// and an operation allowlist. Prefer it wherever you have a backend.
    ///
    /// The `appId` still identifies the surface in the frame's URL.
    case token(String, appId: String)

    /// The `native:<app-id>` this credential asserts, un-normalized.
    public var appId: String {
        switch self {
        case .publishableKey(_, let appId), .token(_, let appId): return appId
        }
    }
}

/// Everything needed to open the editor.
///
/// ```swift
/// let config = SnapneditCanvasConfiguration(
///     credential: .publishableKey("pk_live_…", appId: "com.acme.photos")
/// )
/// ```
public struct SnapneditCanvasConfiguration: Hashable, Sendable {
    /// The snapnedit origin. Point it at your own deployment, or at a local
    /// stack while developing.
    public var baseURL: URL

    /// How the session authenticates.
    public var credential: SnapneditCredential

    /// UI locale, e.g. `"en"`. Unknown values fall back to the default.
    public var locale: String?

    /// Applied with `setTheme` as soon as the editor is ready. Theme is not a
    /// URL parameter: it arrives as an ordinary call, so you can retheme at
    /// runtime with ``SnapneditEditorHandle/setTheme(_:)``.
    public var theme: SnapneditTheme?

    /// Applied with `setFeatures` as soon as the editor is ready.
    public var features: SnapneditFeatures?

    /// Per-call deadlines.
    public var timeouts: SnapneditTimeouts

    public init(
        baseURL: URL = SnapneditProtocol.defaultBaseURL,
        credential: SnapneditCredential,
        locale: String? = nil,
        theme: SnapneditTheme? = nil,
        features: SnapneditFeatures? = nil,
        timeouts: SnapneditTimeouts = .default
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.locale = locale
        self.theme = theme
        self.features = features
        self.timeouts = timeouts
    }

    /// The `native:<app-id>` the frame will assert, lower-cased and validated
    /// against the api's `NATIVE_APP_ID_RE`.
    ///
    /// - Throws: ``SnapneditError`` with ``SnapneditErrorCode/invalidInput``
    ///   when the app id is malformed. The frame refuses to boot on a bad one
    ///   and installs no bridge, so catching it here turns a blank webview
    ///   into a real error.
    public func nativeOrigin() throws -> String {
        guard let origin = SnapneditProtocol.normalizeNativeOrigin(credential.appId) else {
            throw SnapneditError(
                code: .invalidInput,
                message: "`\(credential.appId)` is not a valid native app id: it must start with a letter or digit and contain only letters, digits, `.`, `_` and `-` (2–128 characters)"
            )
        }
        return origin
    }

    /// The URL to load in the webview:
    /// `<baseURL>/embed?transport=native&origin=native:<app-id>&key=…`.
    ///
    /// Keep it out of shared browsing history and out of your logs — it
    /// carries the credential, because there is no host page to hand one over
    /// from.
    public func frameURL() throws -> URL {
        let origin = try nativeOrigin()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components != nil else {
            throw SnapneditError(code: .invalidInput, message: "`\(baseURL)` is not a usable base URL")
        }
        // Preserve a base URL that already carries a path prefix.
        let basePath = components!.path.hasSuffix("/") ? String(components!.path.dropLast()) : components!.path
        components!.path = basePath + SnapneditProtocol.embedPath
        var items = [
            URLQueryItem(name: "transport", value: SnapneditProtocol.nativeTransport),
            URLQueryItem(name: "origin", value: origin),
        ]
        switch credential {
        case .publishableKey(let key, _): items.append(URLQueryItem(name: "key", value: key))
        case .token(let token, _): items.append(URLQueryItem(name: "token", value: token))
        }
        if let locale, !locale.isEmpty { items.append(URLQueryItem(name: "locale", value: locale)) }
        components!.queryItems = items
        guard let url = components!.url else {
            throw SnapneditError(code: .invalidInput, message: "could not build the embed frame URL from `\(baseURL)`")
        }
        return url
    }
}
