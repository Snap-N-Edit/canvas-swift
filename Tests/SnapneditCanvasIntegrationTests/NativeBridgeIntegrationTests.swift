#if os(macOS)
import AppKit
import XCTest
import WebKit
@testable import SnapneditCanvas

/// The wrapper against a REAL editor in a REAL `WKWebView`.
///
/// Everything else in this package is tested against a fake transport, which
/// proves the protocol layer but says nothing about the two lines that actually
/// touch WebKit: the `snapnedit` script-message handler, and the
/// `evaluateJavaScript` literal. This target closes that gap.
///
/// It is SKIPPED unless `SNAPNEDIT_E2E_URL` points at a running snapnedit
/// stack, because it needs one. To run it against the monorepo's own e2e
/// stack, from the repository root:
///
/// ```sh
/// # once, if apps/web/.next is missing or was built with output: 'standalone'
/// NEXT_DISABLE_STANDALONE=1 npm run build:web
/// npm run build
///
/// # the same two processes playwright.config.ts boots
/// DB_DRIVER=memory JOB_QUEUE_DRIVER=memory USE_STUB=on STOCK_STUB=on \
///   STORAGE_DRIVER=local SIGNING_SECRET=e2e-secret METERING=off BOT_PROTECTION=off \
///   RATE_LIMIT_MAX=100000 HOST=127.0.0.1 PORT=8787 JWT_SECRET=e2e-jwt \
///   EMBED_ALLOW_ANY_ORIGIN=on NODE_ENV=development \
///   SEED_EMBED_KEY_NATIVE=pk_live_local-dev-embed-native-00000000000000 \
///   SEED_EMBED_KEY_NATIVE_ORIGIN=native:e2e.app \
///   node apps/dev/dist/main.js &
/// API_PROXY_TARGET=http://127.0.0.1:8787 NEXT_PUBLIC_API_BASE=/api PORT=3000 \
///   NEXT_DISABLE_STANDALONE=1 \
///   npm run start --workspace=@snapnedit/web &
///
/// SNAPNEDIT_E2E_URL=http://localhost:3000 swift test --filter Integration
/// ```
final class NativeBridgeIntegrationTests: XCTestCase {
    /// The publishable key `apps/dev/src/main.ts` seeds when
    /// `SEED_EMBED_KEY_NATIVE` is set, whose origin allowlist holds
    /// `native:e2e.app` and NOTHING else — so a pass here means the native
    /// allowlist genuinely matched rather than a `*` waving it through.
    static let nativeKey = "pk_live_local-dev-embed-native-00000000000000"
    static let nativeAppID = "e2e.app"

    private var window: NSWindow?
    private var canvas: SnapneditCanvasView?

    override func tearDown() {
        let window = self.window
        let canvas = self.canvas
        self.window = nil
        self.canvas = nil
        DispatchQueue.main.async {
            canvas?.handle.destroy()
            window?.close()
        }
        super.tearDown()
    }

    /// `SNAPNEDIT_E2E_URL`, or a skip explaining exactly how to provide it.
    private func requireStackURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["SNAPNEDIT_E2E_URL"], !raw.isEmpty, let url = URL(string: raw) else {
            throw XCTSkip("""
                SNAPNEDIT_E2E_URL is not set, so there is no snapnedit stack to drive a real WKWebView against.
                Start one (see the comment at the top of this file) and re-run with, for example:
                  SNAPNEDIT_E2E_URL=http://localhost:3000 swift test --filter Integration
                """)
        }
        return url
    }

    /// The whole exchange, driven from a synchronous test so `wait(for:)` pumps
    /// the main run loop — WebKit needs the run loop serviced to load a page at
    /// all, and an `async` test alone does not guarantee that under `swift test`.
    func testLoadRunExportOverARealWKWebView() throws {
        let baseURL = try requireStackURL()
        let finished = expectation(description: "the native round trip finished")
        let outcome = Outcome()

        Task { @MainActor in
            do {
                try await self.roundTrip(baseURL: baseURL)
            } catch {
                outcome.error = error
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 300)
        if let error = outcome.error { throw error }
    }

    /// A box, so the `Task` can report back to a synchronous test body.
    private final class Outcome: @unchecked Sendable {
        var error: Error?
    }

    @MainActor
    private func roundTrip(baseURL: URL) async throws {
        // WKWebView needs an app and a window: it will not run its compositor,
        // and Pixi will not get a WebGL context, for a view that is in no
        // window at all.
        NSApplication.shared.setActivationPolicy(.accessory)
        let configuration = SnapneditCanvasConfiguration(
            baseURL: baseURL,
            credential: .publishableKey(Self.nativeKey, appId: Self.nativeAppID),
            locale: "en",
            timeouts: SnapneditTimeouts(call: 60, longRunningCall: 180, ready: 120)
        )
        let canvas = try SnapneditCanvasView(configuration: configuration)
        self.canvas = canvas

        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        // Off-screen but ORDERED IN: an un-ordered window's webview never
        // composites, and `orderFrontRegardless` does not steal focus.
        window.orderFrontRegardless()
        self.window = window

        let handle = canvas.handle

        // ── 1. ready ─────────────────────────────────────────────────────
        var events: [SnapneditCanvasEvent] = []
        handle.onEvent = { events.append($0) }
        try await handle.waitUntilReady()
        let version = try XCTUnwrap(handle.frameVersion)
        XCTAssertFalse(version.isEmpty, "the frame reported an empty version")
        print("[integration] editor ready, version \(version)")

        // ── 2. loadImage, as a shell hands bytes over ─────────────────────
        let source = try Self.makePNG(width: 40, height: 30)
        try await handle.loadImage(data: source, mime: "image/png", name: "fixture.png")
        let loaded = try await handle.getState()
        XCTAssertEqual(loaded.width, 40, "the document should be sized to the image")
        XCTAssertEqual(loaded.height, 30)

        // ── 3. run one operation ─────────────────────────────────────────
        let run = try await handle.run(.resizeImage, params: ["width": 20])
        XCTAssertEqual(run.operation, .resizeImage)
        let jobStatuses = events.compactMap { event -> SnapneditJobEvent.Status? in
            guard case .job(let job) = event, job.operation == .resizeImage else { return nil }
            return job.status
        }
        XCTAssertEqual(jobStatuses, [.started, .succeeded], "the job's own events must reach the shell")

        // ── 4. export, the one result that is not natively JSON-safe ──────
        let exported = try await handle.export(.png)
        XCTAssertEqual(exported.mime, "image/png")
        XCTAssertGreaterThan(exported.data.count, 100)
        XCTAssertEqual(
            Array(exported.data.prefix(8)),
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "the decoded bytes must be a real PNG, not a mangled data: URL"
        )
        let dimensions = try XCTUnwrap(Self.pngDimensions(exported.data))
        XCTAssertEqual(dimensions.width, exported.width, "IHDR must agree with the reported width")
        XCTAssertEqual(dimensions.height, exported.height)
        // `run('resize-image')` resamples the LAYER; the document keeps the
        // size it was loaded at, exactly as `e2e/embed-native.spec.ts` asserts
        // on the same flow.
        XCTAssertEqual(dimensions.width, 40)

        // ── 5. a 20px export, through the options the frame renders with ──
        let small = try await handle.export(.png, options: SnapneditExportOptions(targetWidth: 20))
        let smallDimensions = try XCTUnwrap(Self.pngDimensions(small.data))
        XCTAssertEqual(smallDimensions.width, 20, "targetWidth must reach the frame's renderer")
        print("[integration] exported \(dimensions) and \(smallDimensions)")

        // ── 6. undo/redo and teardown ────────────────────────────────────
        try await handle.undo()
        let afterUndo = try await handle.getState()
        XCTAssertTrue(afterUndo.canRedo, "undo must be observable through getState")

        handle.destroy()
        do {
            try await handle.undo()
            XCTFail("a destroyed handle must refuse further calls")
        } catch let error as SnapneditError {
            XCTAssertEqual(error.code, .destroyed)
        }
    }

    /// An app id the seeded key does NOT allow must be refused before `ready`,
    /// with `origin_denied` — the proof that the allowlist is real.
    func testRefusedAppIDFailsTheBoot() throws {
        let baseURL = try requireStackURL()
        let finished = expectation(description: "the boot failed")
        let outcome = Outcome()

        Task { @MainActor in
            do {
                NSApplication.shared.setActivationPolicy(.accessory)
                let configuration = SnapneditCanvasConfiguration(
                    baseURL: baseURL,
                    credential: .publishableKey(Self.nativeKey, appId: "not.allowed.app"),
                    timeouts: SnapneditTimeouts(call: 30, longRunningCall: 60, ready: 120)
                )
                let canvas = try SnapneditCanvasView(configuration: configuration)
                self.canvas = canvas
                let window = NSWindow(
                    contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.contentView = canvas
                window.orderFrontRegardless()
                self.window = window
                do {
                    try await canvas.handle.waitUntilReady()
                    XCTFail("a key that does not allow this app id must not reach `ready`")
                } catch let error as SnapneditError {
                    XCTAssertEqual(error.code, .originDenied)
                }
            } catch {
                outcome.error = error
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 300)
        if let error = outcome.error { throw error }
    }

    // MARK: - Fixtures

    /// A solid PNG of the given size, so the test carries no binary fixture.
    static func makePNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The IHDR dimensions, read straight out of the bytes — decoding through
    /// `NSImage` would happily "read" something that is not a PNG at all.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        func be32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        guard Array(bytes[12..<16]) == Array("IHDR".utf8) else { return nil }
        return (be32(16), be32(20))
    }
}
#endif
