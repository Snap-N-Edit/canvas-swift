import Foundation

/// Every code an error from the editor can carry — the `errorCodes` list in
/// `packages/embed/protocol.json`, all 22 of them.
///
/// A `RawRepresentable` struct rather than an `enum` so a code introduced by a
/// newer frame arrives intact instead of failing to decode. The static members
/// still pattern-match in a `switch`:
///
/// ```swift
/// catch let error as SnapneditError {
///     switch error.code {
///     case .paymentRequired: presentTopUp()
///     case .maskRequired:    try await handle.openTool(.magicEraser)
///     default:               report(error)
///     }
/// }
/// ```
public struct SnapneditErrorCode: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    // ── The api's own codes ─────────────────────────────────────────────
    /// Bad arguments — a malformed url, an unknown format, a header off the allowlist.
    public static let invalidInput = SnapneditErrorCode("invalid_input")
    /// The uploaded bytes are not an image type the operation accepts.
    public static let unsupportedMime = SnapneditErrorCode("unsupported_mime")
    /// The input exceeds the upload ceiling.
    public static let tooLarge = SnapneditErrorCode("too_large")
    /// The referenced asset, job or destination does not exist.
    public static let notFound = SnapneditErrorCode("not_found")
    /// A `inputUrl` job's fetch failed (DNS, TLS, a redirect, a non-image body).
    public static let inputFetchFailed = SnapneditErrorCode("input_fetch_failed")
    /// A provider ran and failed.
    public static let providerFailed = SnapneditErrorCode("provider_failed")
    /// Every provider for the operation failed.
    public static let providerExhausted = SnapneditErrorCode("provider_exhausted")
    /// A rate limit was hit — the key's, the ip's, or the account's.
    public static let rateLimited = SnapneditErrorCode("rate_limited")
    /// Bot protection refused the request.
    public static let botCheckFailed = SnapneditErrorCode("bot_check_failed")
    /// The credential is missing, malformed, or revoked.
    public static let unauthorized = SnapneditErrorCode("unauthorized")
    /// Authenticated, but not allowed to do this.
    public static let forbidden = SnapneditErrorCode("forbidden")
    /// Out of credits.
    public static let paymentRequired = SnapneditErrorCode("payment_required")
    /// Something broke on our side.
    public static let internalError = SnapneditErrorCode("internal")

    // ── Embed lifecycle codes ───────────────────────────────────────────
    /// A call was issued before the editor was ready, or after a boot failure.
    public static let notReady = SnapneditErrorCode("not_ready")
    /// A mask-guided operation reached `run` without a painted mask — open the
    /// tool instead: `openTool(.magicEraser)`.
    public static let maskRequired = SnapneditErrorCode("mask_required")
    /// The call did not answer within its deadline (see ``SnapneditTimeouts``).
    public static let timeout = SnapneditErrorCode("timeout")
    /// The publishable key does not allow this `native:<app-id>`. Add it under
    /// dashboard → API keys → Allowed origins.
    public static let originDenied = SnapneditErrorCode("origin_denied")
    /// The handle was destroyed, or its view went away, while the call was in flight.
    public static let destroyed = SnapneditErrorCode("destroyed")
    /// The embed session token ran out and nothing replaced it.
    public static let tokenExpired = SnapneditErrorCode("token_expired")
    /// An `exportTo` upload never got a response: DNS, TLS, a bucket CORS rule
    /// that does not allow the EDITOR frame's origin, or a redirect.
    public static let networkError = SnapneditErrorCode("network_error")
    /// The bucket answered an `exportTo` upload with a non-2xx status, carried
    /// in ``SnapneditError/details`` as `status`.
    public static let uploadFailed = SnapneditErrorCode("upload_failed")
    /// The editor frame does not implement the method you called — your app is
    /// newer than the deployed `/embed`.
    public static let unsupported = SnapneditErrorCode("unsupported")

    /// All 22 codes, in `protocol.json` order.
    public static let all: [SnapneditErrorCode] = [
        .invalidInput, .unsupportedMime, .tooLarge, .notFound, .inputFetchFailed,
        .providerFailed, .providerExhausted, .rateLimited, .botCheckFailed,
        .unauthorized, .forbidden, .paymentRequired, .internalError, .notReady,
        .maskRequired, .timeout, .originDenied, .destroyed, .tokenExpired,
        .networkError, .uploadFailed, .unsupported,
    ]
}

/// A failure reported by the editor, or by this wrapper on the editor's behalf.
public struct SnapneditError: Error, Hashable, Sendable, CustomStringConvertible {
    /// What went wrong, as a switchable code.
    public let code: SnapneditErrorCode
    /// A human-readable explanation from the frame. Not for pattern matching.
    public let message: String
    /// Structured context for the codes that carry any — today
    /// ``SnapneditErrorCode/uploadFailed``, with `status`.
    public let details: [String: JSONValue]?

    public init(code: SnapneditErrorCode, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// Convenience for the one code that carries structured detail today.
    public var uploadStatus: Int? { details?["status"]?.intValue }

    public var description: String { "\(code.rawValue): \(message)" }
}

extension SnapneditError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The untyped view of ``SnapneditError/details``, for call sites that would
/// rather have `[String: Any]`.
extension SnapneditError {
    public var detailsAny: [String: Any]? { details?.mapValues(\.anyValue) }
}
