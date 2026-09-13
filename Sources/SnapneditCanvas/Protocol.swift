import Foundation

/// The wire protocol constants, mirroring `packages/embed/protocol.json`
/// (version 1) exactly.
///
/// Nothing in here touches WebKit: the whole protocol layer is a pure
/// value-level translation of JSON strings, which is what makes it testable
/// against a fake transport.
public enum SnapneditProtocol {
    /// Stamped on every envelope as `snapnedit: <version>`.
    public static let version = 1

    /// The JavaScript global the frame installs for the shell to push into:
    /// `window.SnapneditNativeBridge.receive(json)`.
    public static let bridgeGlobal = "SnapneditNativeBridge"

    /// The `WKScriptMessageHandler` name the frame looks for
    /// (`window.webkit.messageHandlers.snapnedit.postMessage`).
    public static let channelName = "snapnedit"

    /// The query value that switches the frame onto the native transport.
    public static let nativeTransport = "native"

    /// The frame's path on the embed origin.
    public static let embedPath = "/embed"

    /// The default embed origin.
    public static let defaultBaseURL = URL(string: "https://snapnedit.com")!

    /// `native:<app-id>` after lower-casing, matching the api's
    /// `NATIVE_APP_ID_RE` — the frame refuses to boot on anything else, so the
    /// wrapper rejects it before a webview is even created.
    public static func normalizeNativeOrigin(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = value.hasPrefix("native:") ? String(value.dropFirst("native:".count)) : value
        guard (2...128).contains(id.count) else { return nil }
        guard let first = id.first, first.isASCII, first.isLetter || first.isNumber else { return nil }
        for ch in id.dropFirst() {
            guard ch.isASCII, ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" else { return nil }
        }
        return "native:\(id)"
    }
}

// MARK: - Methods

/// Every method the frame answers a `call` for, exactly the `methods` table in
/// `protocol.json`.
public struct SnapneditMethod: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let loadImage = SnapneditMethod("loadImage")
    public static let addImage = SnapneditMethod("addImage")
    public static let loadDocument = SnapneditMethod("loadDocument")
    public static let getDocument = SnapneditMethod("getDocument")
    public static let getPages = SnapneditMethod("getPages")
    public static let newDocument = SnapneditMethod("newDocument")
    public static let export = SnapneditMethod("export")
    public static let exportTo = SnapneditMethod("exportTo")
    public static let listDestinations = SnapneditMethod("listDestinations")
    public static let run = SnapneditMethod("run")
    public static let openTool = SnapneditMethod("openTool")
    public static let undo = SnapneditMethod("undo")
    public static let redo = SnapneditMethod("redo")
    public static let select = SnapneditMethod("select")
    public static let getState = SnapneditMethod("getState")
    public static let setTheme = SnapneditMethod("setTheme")
    public static let setFeatures = SnapneditMethod("setFeatures")
    public static let setLocale = SnapneditMethod("setLocale")

    /// Every method, in `protocol.json` order.
    public static let all: [SnapneditMethod] = [
        .loadImage, .addImage, .loadDocument, .getDocument, .getPages, .newDocument,
        .export, .exportTo, .listDestinations, .run, .openTool, .undo, .redo,
        .select, .getState, .setTheme, .setFeatures, .setLocale,
    ]

    /// The methods `protocol.json` flags `longRunning: true` — a host must
    /// allow minutes for these, not seconds.
    public static let longRunning: Set<SnapneditMethod> = [.loadImage, .addImage, .export, .exportTo, .run]

    /// True when this method should be given ``SnapneditTimeouts/longRunningCall``.
    public var isLongRunning: Bool { SnapneditMethod.longRunning.contains(self) }
}

// MARK: - Events

/// Every event name the frame emits, exactly the `events` table in `protocol.json`.
public struct SnapneditEventName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let ready = SnapneditEventName("ready")
    public static let change = SnapneditEventName("change")
    public static let selection = SnapneditEventName("selection")
    public static let job = SnapneditEventName("job")
    public static let export = SnapneditEventName("export")
    public static let save = SnapneditEventName("save")
    public static let close = SnapneditEventName("close")
    public static let error = SnapneditEventName("error")
    public static let tokenExpiring = SnapneditEventName("token-expiring")

    public static let all: [SnapneditEventName] = [
        .ready, .change, .selection, .job, .export, .save, .close, .error, .tokenExpiring,
    ]
}

// MARK: - Envelopes

/// A message the shell pushes into the frame with
/// `SnapneditNativeBridge.receive(json)`.
public enum SnapneditOutboundEnvelope: Sendable, Equatable {
    /// Invoke one editor method. `id` is opaque to the frame and echoed back.
    case call(id: String, method: SnapneditMethod, args: [JSONValue])
    /// Replace the session token, answering a `token-expiring` event.
    case refreshToken(String)

    /// The exact JSON string that goes into `receive(...)`.
    public func json() throws -> String {
        let envelope: JSONValue
        switch self {
        case .call(let id, let method, let args):
            envelope = .object([
                "snapnedit": .number(Double(SnapneditProtocol.version)),
                "type": .string("call"),
                "id": .string(id),
                "payload": .object(["method": .string(method.rawValue), "args": .array(args)]),
            ])
        case .refreshToken(let token):
            envelope = .object([
                "snapnedit": .number(Double(SnapneditProtocol.version)),
                "type": .string("refresh-token"),
                "payload": .object(["token": .string(token)]),
            ])
        }
        let data = try JSONEncoder().encode(envelope)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SnapneditError(code: .internalError, message: "could not encode the outbound envelope as UTF-8")
        }
        return string
    }
}

/// A message the frame produced, as it arrives from the WKWebView message handler.
public enum SnapneditInboundEnvelope: Sendable, Equatable {
    /// The frame is listening. Sent once, before anything else.
    case readyForInit
    /// An event: a name from ``SnapneditEventName`` plus its payload object.
    case event(name: SnapneditEventName, data: JSONValue)
    /// The answer to one `call`, matched by `id`.
    case result(id: String, outcome: Result<JSONValue, SnapneditError>)

    /// Parses one JSON string from the frame.
    ///
    /// Throws ``SnapneditError`` with `invalid_input` for anything that is not
    /// a well-formed protocol-version-1 envelope — a frame or shell bug we
    /// want surfaced, never silently dropped.
    public static func decode(json: String) throws -> SnapneditInboundEnvelope {
        guard let data = json.data(using: .utf8) else {
            throw SnapneditError(code: .invalidInput, message: "message from the frame was not UTF-8")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SnapneditError(code: .invalidInput, message: "message from the frame was not valid JSON")
        }
        guard value["snapnedit"]?.intValue == SnapneditProtocol.version else {
            throw SnapneditError(
                code: .invalidInput,
                message: "message from the frame is not a snapnedit protocol v\(SnapneditProtocol.version) envelope"
            )
        }
        guard let type = value["type"]?.stringValue else {
            throw SnapneditError(code: .invalidInput, message: "message from the frame has no `type`")
        }
        switch type {
        case "ready-for-init":
            return .readyForInit
        case "event":
            guard let name = value["payload"]?["name"]?.stringValue else {
                throw SnapneditError(code: .invalidInput, message: "event envelope has no `payload.name`")
            }
            return .event(name: SnapneditEventName(name), data: value["payload"]?["data"] ?? .object([:]))
        case "result":
            guard let id = value["id"]?.stringValue else {
                throw SnapneditError(code: .invalidInput, message: "result envelope has no `id`")
            }
            let payload = value["payload"] ?? .object([:])
            if payload["ok"]?.boolValue == true {
                return .result(id: id, outcome: .success(payload["value"] ?? .null))
            }
            let error = payload["error"]
            let code = SnapneditErrorCode(rawValue: error?["code"]?.stringValue ?? SnapneditErrorCode.internalError.rawValue)
            let message = error?["message"]?.stringValue ?? "the editor reported a failure with no message"
            return .result(id: id, outcome: .failure(SnapneditError(code: code, message: message, details: error?["details"]?.objectValue)))
        default:
            throw SnapneditError(code: .invalidInput, message: "unknown envelope type `\(type)`")
        }
    }
}

// MARK: - Unknown-method detection

extension SnapneditError {
    /// The `invalid_input` message an OLDER frame answers a method it has
    /// never heard of with. Recognizing it is what lets the wrapper report
    /// `unsupported` — "your app is newer than the editor" — rather than a
    /// baffling "invalid input" for a perfectly good call.
    static func unknownMethodMessage(_ method: SnapneditMethod) -> String {
        "unknown method \(method.rawValue)"
    }

    /// Re-codes an older frame's "unknown method" refusal as ``SnapneditErrorCode/unsupported``.
    func mappingUnknownMethod(_ method: SnapneditMethod) -> SnapneditError {
        guard code == .invalidInput, message == SnapneditError.unknownMethodMessage(method) else { return self }
        return SnapneditError(
            code: .unsupported,
            message: "the editor frame does not implement `\(method.rawValue)` — it is older than this wrapper",
            details: details
        )
    }
}
