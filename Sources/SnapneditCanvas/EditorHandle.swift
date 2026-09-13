import Foundation

/// The editor, as your app talks to it.
///
/// Every method is one `call` envelope across the bridge and one `result`
/// back, matched by id. Calls issued before the frame reports `ready` are
/// queued rather than refused, so you can drive the editor the moment you have
/// a handle:
///
/// ```swift
/// try await handle.loadImage(image)
/// let run = try await handle.run(.removeBackground)
/// let png = try await handle.export(.png)
/// ```
///
/// Main-actor isolated (and therefore `Sendable`): the WKWebView it drives is,
/// and keeping the pending-call table on one actor is what makes id matching
/// and timeout cancellation race-free.
@MainActor
public final class SnapneditEditorHandle {
    // MARK: Lifecycle state

    enum Phase {
        case booting
        case ready(version: String)
        case failed(SnapneditError)
        case destroyed
    }

    private let transport: SnapneditTransport
    private let timeouts: SnapneditTimeouts
    private var phase: Phase = .booting

    /// True once the frame has emitted `ready`.
    public var isReady: Bool { if case .ready = phase { return true }; return false }

    /// The frame's version, once it has reported one.
    public private(set) var frameVersion: String?

    // MARK: Call plumbing

    private struct Pending {
        let method: SnapneditMethod
        let continuation: CheckedContinuation<JSONValue, Error>
        /// Started when the envelope is actually SENT, not when the call was
        /// issued: a call queued behind a slow boot must not spend its own
        /// deadline waiting for the editor to exist.
        var timeout: Task<Void, Never>?
    }

    private var pending: [String: Pending] = [:]
    /// Envelopes issued before `ready`, in the order `call` was entered.
    private var outbox: [(id: String, json: String)] = []
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var bootTimeout: Task<Void, Never>?
    private var callCounter: UInt64 = 0

    // MARK: Event fan-out

    private var streams: [UUID: AsyncStream<SnapneditCanvasEvent>.Continuation] = [:]

    /// A closure called for every event, on the main actor. An alternative to
    /// ``events`` for hosts that would rather not hold a stream.
    public var onEvent: (@MainActor (SnapneditCanvasEvent) -> Void)?

    /// The delegate half of the same delivery.
    public weak var delegate: (any SnapneditCanvasDelegate)?

    /// Job events observed so far, so ``run(_:params:)`` can report the job id,
    /// the credits charged and the duration — none of which is in `run`'s own
    /// (void) result.
    private var jobSerial = 0
    private var lastJobEvent: [String: (serial: Int, event: SnapneditJobEvent)] = [:]

    // MARK: Init

    /// Builds a handle over any transport. The WKWebView-backed one is created
    /// for you by ``SnapneditCanvasView``; this initializer is what makes the
    /// protocol layer testable with a fake.
    public init(transport: SnapneditTransport, timeouts: SnapneditTimeouts = .default) {
        self.transport = transport
        self.timeouts = timeouts
        transport.onMessage = { [weak self] json in self?.receive(json) }
        let budget = timeouts.ready
        bootTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.failBoot(SnapneditError(
                code: .timeout,
                message: "the editor did not report `ready` within \(Int(budget))s — check the publishable key, the native app id allowlist and the device's connectivity"
            ))
        }
    }

    // MARK: - Events

    /// Every event the editor emits, as an `AsyncStream`. Each access returns
    /// an independent stream, so several parts of your app can listen.
    ///
    /// ``SnapneditCanvasEvent/ready(version:)`` is replayed to a stream opened
    /// after boot, so a late subscriber is not left waiting for an event that
    /// already happened.
    public var events: AsyncStream<SnapneditCanvasEvent> {
        AsyncStream { continuation in
            let id = UUID()
            switch phase {
            case .destroyed:
                continuation.finish()
                return
            case .ready(let version):
                continuation.yield(.ready(version: version))
            case .failed(let error):
                continuation.yield(.error(error))
            case .booting:
                break
            }
            streams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streams[id] = nil }
            }
        }
    }

    private func emit(_ event: SnapneditCanvasEvent) {
        for continuation in streams.values { continuation.yield(event) }
        onEvent?(event)
        delegate?.snapneditCanvas(self, didEmit: event)
        if case .ready(let version) = event { delegate?.snapneditCanvasDidBecomeReady(self, version: version) }
    }

    // MARK: - Inbound

    /// Feeds one JSON string from the frame in. Called by the transport; it is
    /// `public` so a custom transport (a WebView2-style shell, a test double)
    /// can drive the handle the same way.
    public func receive(_ json: String) {
        let envelope: SnapneditInboundEnvelope
        do {
            envelope = try SnapneditInboundEnvelope.decode(json: json)
        } catch let error as SnapneditError {
            emit(.error(error))
            return
        } catch {
            emit(.error(SnapneditError(code: .invalidInput, message: "could not read a message from the editor: \(error)")))
            return
        }

        switch envelope {
        case .readyForInit:
            // A native frame synthesizes its own `init` from the URL query, so
            // there is nothing to answer. Recorded for symmetry with the web
            // loader, which replies here.
            break

        case .event(let name, let data):
            let event = SnapneditCanvasEvent.decode(name: name, data: data)
            if case .job(let job) = event, job.status != .started {
                jobSerial += 1
                lastJobEvent[job.operation.rawValue] = (jobSerial, job)
            }
            switch event {
            case .ready(let version):
                becomeReady(version: version)
            case .error(let error):
                // Before `ready` an error is a fatal boot failure (typically
                // `origin_denied`); after it, informational.
                if case .booting = phase { failBoot(error) }
            default:
                break
            }
            emit(event)

        case .result(let id, let outcome):
            guard let entry = pending.removeValue(forKey: id) else { return }
            entry.timeout?.cancel()
            switch outcome {
            case .success(let value):
                entry.continuation.resume(returning: value)
            case .failure(let error):
                entry.continuation.resume(throwing: error.mappingUnknownMethod(entry.method))
            }
        }
    }

    private func becomeReady(version: String) {
        guard case .booting = phase else { return }
        phase = .ready(version: version)
        frameVersion = version
        bootTimeout?.cancel()
        bootTimeout = nil
        // The outbox FIRST: a queued call must reach the frame before any
        // `waitUntilReady()` observer gets a chance to issue a new one.
        let queued = outbox
        outbox.removeAll()
        for entry in queued { dispatch(id: entry.id, json: entry.json) }
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func failBoot(_ error: SnapneditError) {
        guard case .booting = phase else { return }
        phase = .failed(error)
        bootTimeout?.cancel()
        bootTimeout = nil
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        failAllPending(with: error)
    }

    private func failAllPending(with error: SnapneditError) {
        let entries = pending
        pending.removeAll()
        outbox.removeAll()
        for entry in entries.values {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    private func failPending(_ id: String, with error: SnapneditError) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        outbox.removeAll { $0.id == id }
        entry.timeout?.cancel()
        entry.continuation.resume(throwing: error)
    }

    /// Sends one queued or fresh envelope and starts its deadline.
    private func dispatch(id: String, json: String) {
        guard var entry = pending[id] else { return }
        let method = entry.method
        let budget = timeouts.deadline(for: method)
        entry.timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.failPending(id, with: SnapneditError(
                code: .timeout,
                message: "`\(method.rawValue)` did not answer within \(Int(budget))s"
            ))
        }
        pending[id] = entry
        transport.send(json)
    }

    // MARK: - Outbound

    /// Suspends until the frame is ready, or throws if the boot failed or the
    /// handle was destroyed. Waiters are resumed in the order they arrived, so
    /// queued calls reach the frame in the order you issued them.
    public func waitUntilReady() async throws {
        switch phase {
        case .ready: return
        case .failed(let error): throw error
        case .destroyed: throw SnapneditError(code: .destroyed, message: "the editor was destroyed")
        case .booting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiters.append(continuation)
            }
        }
    }

    private func nextID() -> String {
        callCounter += 1
        return "s\(callCounter)"
    }

    /// Issues one raw `call` and awaits its `result`.
    ///
    /// Exposed so a host can reach a method a newer frame added before this
    /// wrapper models it. An older frame's "unknown method" refusal comes back
    /// as ``SnapneditErrorCode/unsupported``.
    @discardableResult
    public func call(_ method: SnapneditMethod, _ args: [JSONValue] = []) async throws -> JSONValue {
        switch phase {
        case .failed(let error): throw error
        case .destroyed: throw SnapneditError(code: .destroyed, message: "the editor was destroyed")
        case .ready, .booting: break
        }
        let id = nextID()
        let json = try SnapneditOutboundEnvelope.call(id: id, method: method, args: args).json()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            // Registered BEFORE anything is sent: a frame fast enough to answer
            // inside `send` must still find its pending entry.
            pending[id] = Pending(method: method, continuation: continuation, timeout: nil)
            if isReady {
                dispatch(id: id, json: json)
            } else {
                // The ORDER is fixed here, synchronously, at the moment `call`
                // was entered — not by whatever order the main actor happens to
                // resume three suspended tasks in. Two `loadImage`s racing into
                // the wrong order would silently produce the wrong document.
                outbox.append((id: id, json: json))
            }
        }
    }

    /// Replaces the session token, answering a
    /// ``SnapneditCanvasEvent/tokenExpiring(expiresAt:raw:)`` event. Only
    /// meaningful when your backend mints tokens; a publishable-key session
    /// re-mints itself.
    public func refreshToken(_ token: String) throws {
        if case .destroyed = phase {
            throw SnapneditError(code: .destroyed, message: "the editor was destroyed")
        }
        transport.send(try SnapneditOutboundEnvelope.refreshToken(token).json())
    }

    // MARK: - Teardown

    /// Tears the bridge down: pending calls fail with
    /// ``SnapneditErrorCode/destroyed``, every event stream finishes, and the
    /// transport releases its handler.
    ///
    /// Call it when the screen goes away. ``SnapneditCanvasView`` calls it from
    /// `deinit`, but the `WKUserContentController` holds its message handler
    /// STRONGLY, so a view that is only released — never destroyed — leaks the
    /// webview. Destroying explicitly is the reliable path.
    public func destroy() {
        guard !isDestroyed else { return }
        let error = SnapneditError(code: .destroyed, message: "the editor was destroyed")
        if case .booting = phase {
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: error) }
        }
        phase = .destroyed
        bootTimeout?.cancel()
        bootTimeout = nil
        failAllPending(with: error)
        outbox.removeAll()
        for continuation in streams.values { continuation.finish() }
        streams.removeAll()
        onEvent = nil
        delegate = nil
        transport.onMessage = nil
        transport.teardown()
    }

    /// True once ``destroy()`` has run.
    public var isDestroyed: Bool { if case .destroyed = phase { return true }; return false }
}

// MARK: - The protocol's methods, in `protocol.json` order

extension SnapneditEditorHandle {
    // ── loadImage ───────────────────────────────────────────────────────

    /// Replaces the document with one sized to the image at `url`.
    ///
    /// Must be an absolute `https:` url, and not on the editor frame's own
    /// origin — the frame fetches it with its own credentials and will not be
    /// aimed at itself on a host's behalf. Anything else rejects with
    /// ``SnapneditErrorCode/invalidInput``.
    public func loadImage(url: URL, name: String? = nil) async throws {
        try await call(.loadImage, imageArgs(source: url.absoluteString, name: name))
    }

    /// Replaces the document with one sized to `data`, handed over as a
    /// `data:` URL.
    ///
    /// The whole URL is copied as one JavaScript string, so keep it under a
    /// few megabytes (``SnapneditLimits/recommendedMaxDataURLBytes``). Above
    /// that, upload the photo somewhere reachable over `https:` and use
    /// ``loadImage(url:name:)``.
    public func loadImage(data: Data, mime: String, name: String? = nil) async throws {
        try SnapneditLimits.checkDataURLSize(data, mime: mime)
        try await call(.loadImage, imageArgs(source: SnapneditDataURL.encode(data, mime: mime), name: name))
    }

    /// Replaces the document with one sized to `image`, PNG-encoded.
    public func loadImage(_ image: SnapneditPlatformImage, name: String? = nil) async throws {
        try await loadImage(data: try SnapneditPlatformImageCodec.pngData(image), mime: "image/png", name: name)
    }

    // ── addImage ────────────────────────────────────────────────────────

    /// Adds the image at `url` as a new layer, keeping the current document.
    /// Same url rules as ``loadImage(url:name:)``.
    public func addImage(url: URL, name: String? = nil) async throws {
        try await call(.addImage, imageArgs(source: url.absoluteString, name: name))
    }

    /// Adds `data` as a new layer, keeping the current document.
    public func addImage(data: Data, mime: String, name: String? = nil) async throws {
        try SnapneditLimits.checkDataURLSize(data, mime: mime)
        try await call(.addImage, imageArgs(source: SnapneditDataURL.encode(data, mime: mime), name: name))
    }

    /// Adds `image` as a new layer, PNG-encoded.
    public func addImage(_ image: SnapneditPlatformImage, name: String? = nil) async throws {
        try await addImage(data: try SnapneditPlatformImageCodec.pngData(image), mime: "image/png", name: name)
    }

    private func imageArgs(source: String, name: String?) -> [JSONValue] {
        var args: [JSONValue] = [.string(source)]
        if let name { args.append(.object(["name": .string(name)])) }
        return args
    }

    // ── documents ───────────────────────────────────────────────────────

    /// Replaces the editor's document with `document` — the editor's own
    /// document model, as ``getDocument()`` returned it.
    public func loadDocument(_ document: JSONValue) async throws {
        try await call(.loadDocument, [document])
    }

    /// Swift-flavored alias for ``loadDocument(_:)``.
    public func setDocument(_ document: JSONValue) async throws {
        try await loadDocument(document)
    }

    /// The active document.
    public func getDocument() async throws -> JSONValue {
        try await call(.getDocument)
    }

    /// Every page of the project.
    public func getPages() async throws -> [JSONValue] {
        try await call(.getPages).arrayValue ?? []
    }

    /// Starts an empty document of the given pixel size.
    public func newDocument(width: Int, height: Int) async throws {
        try await call(.newDocument, [.number(Double(width)), .number(Double(height))])
    }

    // ── export ──────────────────────────────────────────────────────────

    /// Renders the document and returns the encoded bytes.
    ///
    /// The bytes cross the bridge as a base64 `data:` URL, so a very large
    /// export is expensive on both sides — prefer ``exportTo(_:options:)``,
    /// which uploads straight from the webview and never copies the file into
    /// your process.
    public func export(_ format: SnapneditExportFormat = .png, options: SnapneditExportOptions = .init()) async throws -> SnapneditExportResult {
        var args: [JSONValue] = [.string(format.rawValue)]
        if !options.isEmpty { args.append(try JSONValue(encoding: options)) }
        let value = try await call(.export, args)
        guard let blob = EncodedBlob(value["blob"]) else {
            throw SnapneditError(code: .internalError, message: "the editor's `export` result carried no readable blob")
        }
        return SnapneditExportResult(
            data: blob.data,
            mime: blob.mime,
            width: value["width"]?.intValue ?? 0,
            height: value["height"]?.intValue ?? 0
        )
    }

    /// Renders exactly what ``export(_:options:)`` renders and uploads the
    /// bytes straight from the webview to a presigned url or a saved storage
    /// destination. Nothing crosses into your app.
    ///
    /// - Throws: ``SnapneditErrorCode/invalidInput`` (bad url, method, format
    ///   or header), ``SnapneditErrorCode/networkError`` (no response at all —
    ///   a bucket CORS rule that does not allow the EDITOR frame's origin, DNS,
    ///   a redirect), or ``SnapneditErrorCode/uploadFailed`` with the bucket's
    ///   status in ``SnapneditError/uploadStatus``.
    @discardableResult
    public func exportTo(_ target: SnapneditExportTarget, options: SnapneditExportOptions = .init()) async throws -> SnapneditExportToResult {
        var args: [JSONValue] = [target.jsonValue()]
        if !options.isEmpty { args.append(try JSONValue(encoding: options)) }
        return try await call(.exportTo, args).decode()
    }

    /// The saved storage destinations on the embed session's account, for a
    /// picker. Empty when the account has none.
    public func listDestinations() async throws -> [SnapneditDestinationSummary] {
        try await call(.listDestinations).decode()
    }

    // ── operations ──────────────────────────────────────────────────────

    /// Runs one AI operation on the current document.
    ///
    /// A mask-guided operation (`magic-eraser`, `remove-watermark`,
    /// `generative-fill`) rejects with ``SnapneditErrorCode/maskRequired``:
    /// open the tool with ``openTool(_:)`` and let the user paint instead.
    @discardableResult
    public func run(_ operation: SnapneditOperation, params: [String: JSONValue] = [:]) async throws -> SnapneditRunResult {
        let mark = jobSerial
        var args: [JSONValue] = [.string(operation.rawValue)]
        if !params.isEmpty { args.append(.object(params)) }
        try await call(.run, args)
        guard let observed = lastJobEvent[operation.rawValue], observed.serial > mark else {
            // A cached result can complete without a job event at all.
            return SnapneditRunResult(operation: operation)
        }
        let job = observed.event
        if job.status == .failed {
            throw job.error ?? SnapneditError(code: .providerFailed, message: "`\(operation.rawValue)` failed")
        }
        return SnapneditRunResult(operation: operation, jobId: job.jobId, credits: job.credits, durationMs: job.durationMs)
    }

    /// Opens the tool panel for an operation.
    public func openTool(_ operation: SnapneditOperation) async throws {
        try await call(.openTool, [.string(operation.rawValue)])
    }

    /// Opens a left-rail section.
    public func openTool(rail: SnapneditRail) async throws {
        try await call(.openTool, [.string(rail.rawValue)])
    }

    // ── history and selection ───────────────────────────────────────────

    public func undo() async throws { try await call(.undo) }
    public func redo() async throws { try await call(.redo) }

    /// Selects layers by id. Pass `[]` to clear.
    public func select(_ ids: [String]) async throws {
        try await call(.select, [.array(ids.map(JSONValue.string))])
    }

    /// A snapshot of the editor: undo/redo availability, selection, page and
    /// document size, dirty and busy flags.
    public func getState() async throws -> SnapneditEditorState {
        try await call(.getState).decode()
    }

    // ── appearance ──────────────────────────────────────────────────────

    public func setTheme(_ theme: SnapneditTheme) async throws {
        try await call(.setTheme, [try JSONValue(encoding: theme)])
    }

    public func setFeatures(_ features: SnapneditFeatures) async throws {
        try await call(.setFeatures, [try JSONValue(encoding: features)])
    }

    public func setLocale(_ locale: String) async throws {
        try await call(.setLocale, [.string(locale)])
    }
}

// MARK: - Untyped conveniences

extension SnapneditEditorHandle {
    /// ``run(_:params:)`` with an untyped parameter dictionary, for call sites
    /// that already have one.
    ///
    /// - Throws: ``SnapneditErrorCode/invalidInput`` when a value is not
    ///   JSON-representable, rather than dropping it on the wire.
    @discardableResult
    public func run(_ operation: SnapneditOperation, params: [String: Any]) async throws -> SnapneditRunResult {
        try await run(operation, params: try Self.encodeParams(params))
    }

    /// ``loadDocument(_:)`` with an untyped document.
    public func setDocument(_ document: [String: Any]) async throws {
        try await loadDocument(.object(try Self.encodeParams(document)))
    }

    static func encodeParams(_ params: [String: Any]) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(params.count)
        for (key, value) in params {
            guard let encoded = JSONValue(any: value) else {
                throw SnapneditError(code: .invalidInput, message: "`\(key)` is not representable as JSON")
            }
            out[key] = encoded
        }
        return out
    }
}

// MARK: - Limits

/// The bridge's practical size ceilings, from `protocol.json`'s
/// `native.payloadLimits`.
public enum SnapneditLimits {
    /// Both directions cross as one string that `evaluateJavaScript` copies
    /// whole. 4 MB of raw bytes is a sane ceiling for an inbound `data:` URL;
    /// above it, hand the frame an `https:` url instead.
    public static let recommendedMaxDataURLBytes = 4 * 1024 * 1024

    /// A hard refusal well above the recommendation, so an accidental 200 MB
    /// image fails fast instead of wedging the webview.
    public static let maxDataURLBytes = 32 * 1024 * 1024

    static func checkDataURLSize(_ data: Data, mime: String) throws {
        guard data.count <= maxDataURLBytes else {
            throw SnapneditError(
                code: .tooLarge,
                message: "\(data.count) bytes of \(mime) is too large for a data: URL across the native bridge (hard limit \(maxDataURLBytes); the recommended ceiling is \(recommendedMaxDataURLBytes)) — upload it and pass an https: URL instead"
            )
        }
    }
}
