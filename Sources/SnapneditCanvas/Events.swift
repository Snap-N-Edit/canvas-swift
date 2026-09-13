import Foundation

/// One `export` event from the frame's own Export menu: the rendered bytes
/// plus the format the menu produced them in (which may be `gif`, the one
/// format a host cannot request).
public struct SnapneditExportEvent: Hashable, Sendable {
    public let format: SnapneditRenderedFormat
    public let result: SnapneditExportResult

    public init(format: SnapneditRenderedFormat, result: SnapneditExportResult) {
        self.format = format
        self.result = result
    }
}

/// One `save` event: the active document and every page of the project, as the
/// editor's own document model.
public struct SnapneditSaveEvent: Hashable, Sendable {
    public let document: JSONValue
    public let pages: [JSONValue]

    public init(document: JSONValue, pages: [JSONValue]) {
        self.document = document
        self.pages = pages
    }
}

/// Everything the editor reports without being asked.
///
/// Delivered through ``SnapneditEditorHandle/events`` (an `AsyncStream`, one
/// per subscriber) and through ``SnapneditEditorHandle/onEvent``. ``ready`` is
/// replayed to late subscribers, so a stream opened after boot still sees it.
public enum SnapneditCanvasEvent: Hashable, Sendable {
    /// The editor mounted and is accepting calls. Carries the frame's version.
    case ready(version: String)
    /// The document changed.
    case change(dirty: Bool, pageCount: Int)
    /// The selection changed. `kind` is the selected layers' shared kind, or `nil`.
    case selection(ids: [String], kind: String?)
    /// An AI job started, succeeded or failed.
    case job(SnapneditJobEvent)
    /// The frame's own Export menu produced a file.
    case export(SnapneditExportEvent)
    /// The user pressed Save.
    case save(SnapneditSaveEvent)
    /// The user pressed Close.
    case close
    /// Something failed outside a specific call. Before ``ready`` this is a
    /// fatal boot failure (typically ``SnapneditErrorCode/originDenied``);
    /// after it, informational.
    case error(SnapneditError)
    /// The embed session token is about to expire. Answer with
    /// ``SnapneditEditorHandle/refreshToken(_:)`` if you mint tokens
    /// server-side; a publishable-key session re-mints itself and you can
    /// ignore it.
    case tokenExpiring(expiresAt: Date?, raw: String)
    /// An event this release does not model — a newer frame. The name and its
    /// raw payload, so nothing is lost.
    case unknown(name: String, data: JSONValue)

    /// The event's protocol name.
    public var name: SnapneditEventName {
        switch self {
        case .ready: return .ready
        case .change: return .change
        case .selection: return .selection
        case .job: return .job
        case .export: return .export
        case .save: return .save
        case .close: return .close
        case .error: return .error
        case .tokenExpiring: return .tokenExpiring
        case .unknown(let name, _): return SnapneditEventName(name)
        }
    }
}

extension SnapneditCanvasEvent {
    /// Builds an event from the `payload` of an `event` envelope.
    ///
    /// Never fails: an event whose payload does not match this release's shape
    /// degrades to ``unknown(name:data:)`` rather than being dropped, so a
    /// frame that adds a field cannot silence an event a host depends on.
    static func decode(name: SnapneditEventName, data: JSONValue) -> SnapneditCanvasEvent {
        switch name {
        case .ready:
            return .ready(version: data["version"]?.stringValue ?? "")
        case .change:
            return .change(dirty: data["dirty"]?.boolValue ?? false, pageCount: data["pageCount"]?.intValue ?? 0)
        case .selection:
            let ids = data["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return .selection(ids: ids, kind: data["kind"]?.stringValue)
        case .job:
            guard let operation = data["operation"]?.stringValue,
                  let status = data["status"]?.stringValue.flatMap(SnapneditJobEvent.Status.init(rawValue:))
            else { return .unknown(name: name.rawValue, data: data) }
            var error: SnapneditError?
            if let raw = data["error"], let code = raw["code"]?.stringValue {
                error = SnapneditError(
                    code: SnapneditErrorCode(code),
                    message: raw["message"]?.stringValue ?? "",
                    details: raw["details"]?.objectValue
                )
            }
            return .job(SnapneditJobEvent(
                operation: SnapneditOperation(operation),
                status: status,
                jobId: data["jobId"]?.stringValue,
                credits: data["credits"]?.intValue ?? 0,
                durationMs: data["durationMs"]?.intValue,
                error: error,
                endUserId: data["endUserId"]?.stringValue
            ))
        case .export:
            guard let format = data["format"]?.stringValue.flatMap(SnapneditRenderedFormat.init(rawValue:)),
                  let blob = EncodedBlob(data["blob"])
            else { return .unknown(name: name.rawValue, data: data) }
            return .export(SnapneditExportEvent(
                format: format,
                result: SnapneditExportResult(
                    data: blob.data,
                    mime: blob.mime,
                    width: data["width"]?.intValue ?? 0,
                    height: data["height"]?.intValue ?? 0
                )
            ))
        case .save:
            return .save(SnapneditSaveEvent(
                document: data["document"] ?? .null,
                pages: data["pages"]?.arrayValue ?? []
            ))
        case .close:
            return .close
        case .error:
            return .error(SnapneditError(
                code: SnapneditErrorCode(data["code"]?.stringValue ?? SnapneditErrorCode.internalError.rawValue),
                message: data["message"]?.stringValue ?? "the editor reported an error with no message",
                details: data["details"]?.objectValue
            ))
        case .tokenExpiring:
            let raw = data["expiresAt"]?.stringValue ?? ""
            return .tokenExpiring(expiresAt: SnapneditCanvasEvent.parseISO8601(raw), raw: raw)
        default:
            return .unknown(name: name.rawValue, data: data)
        }
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain = ISO8601DateFormatter()

    static func parseISO8601(_ value: String) -> Date? {
        iso8601WithFraction.date(from: value) ?? iso8601Plain.date(from: value)
    }
}

/// The delegate half of ``SnapneditEditorHandle``'s event delivery, for hosts
/// that would rather not hold an `AsyncStream`. Every callback is on the main
/// actor.
@MainActor
public protocol SnapneditCanvasDelegate: AnyObject {
    /// The editor mounted. Called once.
    func snapneditCanvasDidBecomeReady(_ handle: SnapneditEditorHandle, version: String)
    /// Any event, including ``SnapneditCanvasEvent/ready(version:)``.
    func snapneditCanvas(_ handle: SnapneditEditorHandle, didEmit event: SnapneditCanvasEvent)
}

public extension SnapneditCanvasDelegate {
    func snapneditCanvasDidBecomeReady(_ handle: SnapneditEditorHandle, version: String) {}
    func snapneditCanvas(_ handle: SnapneditEditorHandle, didEmit event: SnapneditCanvasEvent) {}
}
