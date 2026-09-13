import Foundation

// MARK: - Operations

/// One snapnedit AI operation, as `packages/shared/src/operations.ts` defines
/// it. A struct, not an enum, so an operation shipped after this release still
/// round-trips; the static members pattern-match in a `switch` all the same.
public struct SnapneditOperation: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let removeBackground = SnapneditOperation("remove-background")
    public static let upscale = SnapneditOperation("upscale")
    public static let unblur = SnapneditOperation("unblur")
    public static let colorize = SnapneditOperation("colorize")
    public static let styleTransfer = SnapneditOperation("style-transfer")
    public static let retouch = SnapneditOperation("retouch")
    public static let beautify = SnapneditOperation("beautify")
    public static let magicEraser = SnapneditOperation("magic-eraser")
    public static let generativeFill = SnapneditOperation("generative-fill")
    public static let removeWatermark = SnapneditOperation("remove-watermark")
    public static let aiDenoise = SnapneditOperation("ai-denoise")
    public static let replaceSky = SnapneditOperation("replace-sky")
    public static let relight = SnapneditOperation("relight")
    public static let replaceBackground = SnapneditOperation("replace-background")
    public static let stripMetadata = SnapneditOperation("strip-metadata")
    public static let autoRemoveWatermark = SnapneditOperation("auto-remove-watermark")
    public static let resizeImage = SnapneditOperation("resize-image")

    /// Every operation this release knows about.
    public static let all: [SnapneditOperation] = [
        .removeBackground, .upscale, .unblur, .colorize, .styleTransfer, .retouch,
        .beautify, .magicEraser, .generativeFill, .removeWatermark, .aiDenoise,
        .replaceSky, .relight, .replaceBackground, .stripMetadata,
        .autoRemoveWatermark, .resizeImage,
    ]
}

/// A left-rail section, for ``SnapneditEditorHandle/openTool(rail:)`` and
/// ``SnapneditFeatures/tools``.
public enum SnapneditRail: String, Codable, Hashable, Sendable, CaseIterable {
    case templates, text, shapes, elements, data, uploads, stock, draw, brand, magic, saved
}

/// A right-hand panel, for ``SnapneditFeatures/panels``.
public enum SnapneditPanel: String, Codable, Hashable, Sendable, CaseIterable {
    case layers, adjustments, filters, effects, animation, ai
}

// MARK: - Theme

/// A themeable color slot.
public enum SnapneditThemeColor: String, Codable, Hashable, Sendable, CaseIterable {
    case bg, bg2, surface, surface2, line, line2, text, dim, accent, accentText, checkerA, checkerB
}

/// The editor's look, as ``SnapneditEditorHandle/setTheme(_:)`` takes it.
public struct SnapneditTheme: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable { case dark, light }

    public var mode: Mode?
    public var colors: [SnapneditThemeColor: String]?
    public var accent: String?
    public var font: String?
    public var radius: Double?
    /// Raw CSS injected into the frame. Use sparingly.
    public var css: String?

    public init(
        mode: Mode? = nil,
        colors: [SnapneditThemeColor: String]? = nil,
        accent: String? = nil,
        font: String? = nil,
        radius: Double? = nil,
        css: String? = nil
    ) {
        self.mode = mode
        self.colors = colors
        self.accent = accent
        self.font = font
        self.radius = radius
        self.css = css
    }

    private enum CodingKeys: String, CodingKey { case mode, colors, accent, font, radius, css }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(mode, forKey: .mode)
        // `[SnapneditThemeColor: String]` would encode as an ARRAY through the
        // default synthesis (non-String-keyed dictionaries do); the frame wants
        // an object, so remap the keys explicitly.
        if let colors { try c.encode(Dictionary(uniqueKeysWithValues: colors.map { ($0.key.rawValue, $0.value) }), forKey: .colors) }
        try c.encodeIfPresent(accent, forKey: .accent)
        try c.encodeIfPresent(font, forKey: .font)
        try c.encodeIfPresent(radius, forKey: .radius)
        try c.encodeIfPresent(css, forKey: .css)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode)
        if let raw = try c.decodeIfPresent([String: String].self, forKey: .colors) {
            colors = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
                SnapneditThemeColor(rawValue: key).map { ($0, value) }
            })
        }
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        font = try c.decodeIfPresent(String.self, forKey: .font)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        css = try c.decodeIfPresent(String.self, forKey: .css)
    }
}

// MARK: - Features

/// Which parts of the editor the host exposes, as
/// ``SnapneditEditorHandle/setFeatures(_:)`` takes it.
public struct SnapneditFeatures: Codable, Hashable, Sendable {
    /// How the frame's own Export menu behaves.
    public struct Export: Codable, Hashable, Sendable {
        public enum Mode: String, Codable, Hashable, Sendable { case download, callback, both }
        /// The formats the menu offers. `gif` is not requestable.
        public var formats: [SnapneditExportFormat]?
        public var mode: Mode?
        public init(formats: [SnapneditExportFormat]? = nil, mode: Mode? = nil) {
            self.formats = formats
            self.mode = mode
        }
    }

    public var tools: [SnapneditRail]?
    public var aiOperations: [SnapneditOperation]?
    public var panels: [SnapneditPanel]?
    public var collab: Bool?
    public var stock: Bool?
    public var branding: Bool?
    public var export: Export?
    public var save: Bool?
    public var close: Bool?

    public init(
        tools: [SnapneditRail]? = nil,
        aiOperations: [SnapneditOperation]? = nil,
        panels: [SnapneditPanel]? = nil,
        collab: Bool? = nil,
        stock: Bool? = nil,
        branding: Bool? = nil,
        export: Export? = nil,
        save: Bool? = nil,
        close: Bool? = nil
    ) {
        self.tools = tools
        self.aiOperations = aiOperations
        self.panels = panels
        self.collab = collab
        self.stock = stock
        self.branding = branding
        self.export = export
        self.save = save
        self.close = close
    }

    private enum CodingKeys: String, CodingKey {
        case tools, aiOperations, panels, collab, stock, branding, export, save, close
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(aiOperations?.map(\.rawValue), forKey: .aiOperations)
        try c.encodeIfPresent(panels, forKey: .panels)
        try c.encodeIfPresent(collab, forKey: .collab)
        try c.encodeIfPresent(stock, forKey: .stock)
        try c.encodeIfPresent(branding, forKey: .branding)
        try c.encodeIfPresent(export, forKey: .export)
        try c.encodeIfPresent(save, forKey: .save)
        try c.encodeIfPresent(close, forKey: .close)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent([SnapneditRail].self, forKey: .tools)
        aiOperations = try c.decodeIfPresent([String].self, forKey: .aiOperations)?.map(SnapneditOperation.init(_:))
        panels = try c.decodeIfPresent([SnapneditPanel].self, forKey: .panels)
        collab = try c.decodeIfPresent(Bool.self, forKey: .collab)
        stock = try c.decodeIfPresent(Bool.self, forKey: .stock)
        branding = try c.decodeIfPresent(Bool.self, forKey: .branding)
        export = try c.decodeIfPresent(Export.self, forKey: .export)
        save = try c.decodeIfPresent(Bool.self, forKey: .save)
        close = try c.decodeIfPresent(Bool.self, forKey: .close)
    }
}

// MARK: - Export

/// A format ``SnapneditEditorHandle/export(_:options:)`` and
/// ``SnapneditExportTarget`` accept. `gif` is deliberately absent: the animated
/// GIF is produced only by the frame's own Export menu, and reaches you through
/// the ``SnapneditCanvasEvent/export(_:)`` event as ``SnapneditRenderedFormat/gif``.
public enum SnapneditExportFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case png, jpg, webp, avif, svg, pdf

    /// The mime type the frame produces for this format.
    public var mimeType: String {
        switch self {
        case .png: return "image/png"
        case .jpg: return "image/jpeg"
        case .webp: return "image/webp"
        case .avif: return "image/avif"
        case .svg: return "image/svg+xml"
        case .pdf: return "application/pdf"
        }
    }
}

/// Every format an ``SnapneditCanvasEvent/export(_:)`` event can report —
/// ``SnapneditExportFormat`` plus the menu-only animated `gif`.
public enum SnapneditRenderedFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case png, jpg, webp, avif, svg, pdf, gif

    /// The requestable format, or `nil` for `gif`.
    public var requestable: SnapneditExportFormat? { SnapneditExportFormat(rawValue: rawValue) }
}

/// How to render, for ``SnapneditEditorHandle/export(_:options:)`` and
/// ``SnapneditEditorHandle/exportTo(_:options:)``.
public struct SnapneditExportOptions: Codable, Hashable, Sendable {
    /// Pixel multiplier for the raster. The document is untouched. Ignored by
    /// `svg`; for `pdf` it raises the embedded raster's DPI.
    public var scale: Double?
    /// Target raster width in px. Wins over ``scale`` when both are given.
    public var targetWidth: Int?
    /// Lossy quality 0...1. Honored by `jpg`/`webp`/`avif` only.
    public var quality: Double?
    /// `pdf` only: one PDF containing every project page. Ignored elsewhere.
    public var allPages: Bool?

    public init(scale: Double? = nil, targetWidth: Int? = nil, quality: Double? = nil, allPages: Bool? = nil) {
        self.scale = scale
        self.targetWidth = targetWidth
        self.quality = quality
        self.allPages = allPages
    }

    /// True when nothing was set, so the argument can be omitted entirely.
    var isEmpty: Bool { scale == nil && targetWidth == nil && quality == nil && allPages == nil }
}

/// What ``SnapneditEditorHandle/export(_:options:)`` resolves with: the encoded
/// bytes, their mime type, and the dimensions the frame reports.
public struct SnapneditExportResult: Hashable, Sendable {
    /// The file, decoded from the bridge's `data:` URL.
    public let data: Data
    /// The mime type the frame stamped on the blob.
    public let mime: String
    /// The document's width for `pdf`/`svg`, the rendered bitmap's otherwise.
    public let width: Int
    /// The document's height for `pdf`/`svg`, the rendered bitmap's otherwise.
    public let height: Int

    public init(data: Data, mime: String, width: Int, height: Int) {
        self.data = data
        self.mime = mime
        self.width = width
        self.height = height
    }
}

/// Where ``SnapneditEditorHandle/exportTo(_:options:)`` puts the rendered bytes.
///
/// The upload happens inside the webview: the bytes go straight to your bucket
/// and never cross into your app, which is the whole point for anything large.
public enum SnapneditExportTarget: Hashable, Sendable {
    /// A presigned upload url your own backend minted.
    ///
    /// - Parameters:
    ///   - url: Absolute `https:`, and not on the editor frame's own origin.
    ///   - method: `PUT` (the default) or `POST`.
    ///   - headers: The `x-amz-*`/`x-goog-*`/`x-ms-*`, `content-type`,
    ///     `cache-control` and `content-disposition` headers you signed. At
    ///     most 16; anything else is refused with `invalid_input`.
    ///   - format: What to render. Defaults to `png`.
    case presigned(url: URL, method: HTTPMethod = .put, headers: [String: String] = [:], format: SnapneditExportFormat = .png)

    /// A storage destination already saved on the embed session's account. The
    /// frame asks the api for the signed slot itself: your backend mints
    /// nothing and no bucket detail reaches your app.
    case savedDestination(id: String, format: SnapneditExportFormat = .png, headers: [String: String] = [:])

    public enum HTTPMethod: String, Codable, Hashable, Sendable { case put = "PUT", post = "POST" }

    /// The argument as the frame's `exportTo` expects it.
    func jsonValue() -> JSONValue {
        switch self {
        case .presigned(let url, let method, let headers, let format):
            var object: [String: JSONValue] = [
                "url": .string(url.absoluteString),
                "method": .string(method.rawValue),
                "format": .string(format.rawValue),
            ]
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(object)
        case .savedDestination(let id, let format, let headers):
            var object: [String: JSONValue] = [
                "destinationId": .string(id),
                "format": .string(format.rawValue),
            ]
            if !headers.isEmpty { object["headers"] = .object(headers.mapValues(JSONValue.string)) }
            return .object(object)
        }
    }
}

/// What a successful ``SnapneditEditorHandle/exportTo(_:options:)`` resolves
/// with. A non-2xx REJECTS with ``SnapneditErrorCode/uploadFailed`` rather than
/// resolving, so ``ok`` is always `true`.
public struct SnapneditExportToResult: Codable, Hashable, Sendable {
    public let ok: Bool
    /// The bucket's response status (2xx).
    public let status: Int
    /// Size of the uploaded body.
    public let bytes: Int
    /// Mime type sent as `Content-Type`.
    public let mime: String
    public let width: Int
    public let height: Int
    /// The response's `ETag`, when the bucket exposes it through
    /// `Access-Control-Expose-Headers`.
    public let etag: String?
    /// The object key written. Saved-destination uploads only.
    public let key: String?
    /// The bucket written to. Saved-destination uploads only.
    public let bucket: String?
}

/// Every backend a saved destination can point at.
public enum SnapneditStorageProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case awsS3 = "aws-s3"
    case cloudflareR2 = "cloudflare-r2"
    case backblazeB2 = "backblaze-b2"
    case s3Compatible = "s3-compatible"
}

/// One of the account's saved storage destinations, as
/// ``SnapneditEditorHandle/listDestinations()`` reports it — enough to render a
/// picker and deliberately nothing more.
public struct SnapneditDestinationSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let provider: SnapneditStorageProvider
    public let bucket: String
    /// True for the destination the account delivers to when a job names none.
    public let isDefault: Bool
}

// MARK: - State

/// A snapshot of the editor, as ``SnapneditEditorHandle/getState()`` reports it.
public struct SnapneditEditorState: Codable, Hashable, Sendable {
    public let canUndo: Bool
    public let canRedo: Bool
    public let selection: [String]
    public let page: Int
    public let pageCount: Int
    public let width: Int
    public let height: Int
    public let dirty: Bool
    public let busy: Bool
}

// MARK: - Jobs

/// What ``SnapneditEditorHandle/run(_:params:)`` reports about the job it ran.
///
/// `run` itself resolves with nothing on the wire; this is assembled from the
/// `job` events the frame emitted while the call was in flight, which is the
/// only place the job id, the credits charged and the duration appear.
public struct SnapneditRunResult: Hashable, Sendable {
    public let operation: SnapneditOperation
    /// The api's job id, when the frame reported one.
    public let jobId: String?
    /// Credits charged. `0` for a free operation or a cache hit.
    public let credits: Int
    /// Wall-clock duration the frame measured, in milliseconds.
    public let durationMs: Int?

    public init(operation: SnapneditOperation, jobId: String? = nil, credits: Int = 0, durationMs: Int? = nil) {
        self.operation = operation
        self.jobId = jobId
        self.credits = credits
        self.durationMs = durationMs
    }
}

/// One `job` event.
public struct SnapneditJobEvent: Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable { case started, succeeded, failed }

    public let operation: SnapneditOperation
    public let status: Status
    public let jobId: String?
    public let credits: Int
    public let durationMs: Int?
    /// Present only on `failed`.
    public let error: SnapneditError?
    /// The end-user id a host-minted token attributed the job to.
    public let endUserId: String?

    public init(
        operation: SnapneditOperation,
        status: Status,
        jobId: String? = nil,
        credits: Int = 0,
        durationMs: Int? = nil,
        error: SnapneditError? = nil,
        endUserId: String? = nil
    ) {
        self.operation = operation
        self.status = status
        self.jobId = jobId
        self.credits = credits
        self.durationMs = durationMs
        self.error = error
        self.endUserId = endUserId
    }
}
