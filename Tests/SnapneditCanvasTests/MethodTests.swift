import Foundation
import XCTest
@testable import SnapneditCanvas

/// Every method's argument encoding and result decoding, against the shapes
/// `protocol.json` and `types.ts` specify.
@MainActor
final class MethodTests: XCTestCase {
    /// Drives one method to completion, answering it with `value`, and returns
    /// the call the shell produced.
    private func exercise(
        _ method: SnapneditMethod,
        value: JSONValue = .null,
        _ body: @escaping @MainActor (SnapneditEditorHandle) async throws -> Void
    ) async throws -> FakeTransport.SentCall {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await body(handle) }
        let call = try await transport.awaitCall(method)
        transport.pushResult(id: call.id, value: value)
        try await task.value
        return call
    }

    // MARK: - Images in

    func testLoadImageFromURL() async throws {
        let call = try await exercise(.loadImage) { handle in
            try await handle.loadImage(url: URL(string: "https://cdn.example/photo.jpg")!)
        }
        XCTAssertEqual(call.args.count, 1)
        XCTAssertEqual(call.args[0].stringValue, "https://cdn.example/photo.jpg")
    }

    func testLoadImageFromDataBecomesADataURL() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let call = try await exercise(.loadImage) { handle in
            try await handle.loadImage(data: bytes, mime: "image/png", name: "shot.png")
        }
        XCTAssertEqual(call.args[0].stringValue, "data:image/png;base64,\(bytes.base64EncodedString())")
        XCTAssertEqual(call.args[1]["name"]?.stringValue, "shot.png")
    }

    /// The `{ name }` options object is only sent when there is a name — an
    /// explicit `{}` would be noise on the wire.
    func testLoadImageOmitsEmptyOptions() async throws {
        let call = try await exercise(.loadImage) { handle in
            try await handle.loadImage(data: Data([1]), mime: "image/png")
        }
        XCTAssertEqual(call.args.count, 1)
    }

    func testAddImageUsesItsOwnMethod() async throws {
        let call = try await exercise(.addImage) { handle in
            try await handle.addImage(url: URL(string: "https://cdn.example/layer.png")!, name: "layer")
        }
        XCTAssertEqual(call.method, "addImage")
        XCTAssertEqual(call.args[1]["name"]?.stringValue, "layer")
    }

    /// A data: URL crosses as one JavaScript string that `evaluateJavaScript`
    /// copies whole, so an absurd one is refused here rather than wedging the
    /// webview.
    func testOversizeDataURLIsRefusedLocally() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let huge = Data(count: SnapneditLimits.maxDataURLBytes + 1)
        await assertThrows(.tooLarge) { try await handle.loadImage(data: huge, mime: "image/png") }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: - Documents

    func testNewDocument() async throws {
        let call = try await exercise(.newDocument) { try await $0.newDocument(width: 1080, height: 1350) }
        XCTAssertEqual(call.args[0].intValue, 1080)
        XCTAssertEqual(call.args[1].intValue, 1350)
    }

    func testGetDocumentReturnsTheRawModel() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.getDocument() }
        let call = try await transport.awaitCall(.getDocument)
        transport.pushResult(id: call.id, value: .object(["width": 640, "layers": .array([.object(["id": "a"])])]))
        let document = try await task.value
        XCTAssertEqual(document["width"]?.intValue, 640)
        XCTAssertEqual(document["layers"]?[0]?["id"]?.stringValue, "a")
    }

    func testGetPagesReturnsAnArray() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.getPages() }
        let call = try await transport.awaitCall(.getPages)
        transport.pushResult(id: call.id, value: .array([.object(["width": 1]), .object(["width": 2])]))
        let pages = try await task.value
        XCTAssertEqual(pages.count, 2)
    }

    func testSetDocumentIsLoadDocument() async throws {
        let call = try await exercise(.loadDocument) { try await $0.setDocument(.object(["width": 100])) }
        XCTAssertEqual(call.method, "loadDocument")
        XCTAssertEqual(call.args[0]["width"]?.intValue, 100)
    }

    func testSetDocumentAcceptsAnUntypedDictionary() async throws {
        let call = try await exercise(.loadDocument) { try await $0.setDocument(["width": 100, "name": "hero"]) }
        XCTAssertEqual(call.args[0]["name"]?.stringValue, "hero")
    }

    // MARK: - Export

    func testExportDecodesTheBlobReplacement() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let task = Task { try await handle.export(.png) }
        let call = try await transport.awaitCall(.export)
        XCTAssertEqual(call.args.count, 1, "an empty options object must not be sent")
        XCTAssertEqual(call.args[0].stringValue, "png")
        transport.pushResult(id: call.id, value: .object([
            "blob": .object([
                "dataUrl": .string(SnapneditDataURL.encode(png, mime: "image/png")),
                "mime": "image/png",
                "bytes": .number(Double(png.count)),
            ]),
            "width": 20,
            "height": 15,
        ]))
        let result = try await task.value
        XCTAssertEqual(result.data, png)
        XCTAssertEqual(result.mime, "image/png")
        XCTAssertEqual(result.width, 20)
        XCTAssertEqual(result.height, 15)
    }

    func testExportSendsOptionsWhenGiven() async throws {
        let call = try await exercise(
            .export,
            value: .object(["blob": .object(["dataUrl": "data:image/png;base64,", "mime": "image/png", "bytes": 0]), "width": 1, "height": 1])
        ) { handle in
            _ = try await handle.export(.jpg, options: SnapneditExportOptions(targetWidth: 800, quality: 0.8))
        }
        XCTAssertEqual(call.args[0].stringValue, "jpg")
        XCTAssertEqual(call.args[1]["targetWidth"]?.intValue, 800)
        XCTAssertEqual(call.args[1]["quality"]?.doubleValue, 0.8)
        XCTAssertNil(call.args[1]["scale"], "an unset option must be absent, not null")
    }

    /// A result whose blob we cannot read is a frame bug — surfaced, never
    /// resolved with empty `Data`.
    func testExportWithoutAReadableBlobFails() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.export(.png) }
        let call = try await transport.awaitCall(.export)
        transport.pushResult(id: call.id, value: .object(["blob": .object([:]), "width": 1, "height": 1]))
        await assertThrows(.internalError) { _ = try await task.value }
    }

    func testExportToPresignedTargetEncoding() async throws {
        let call = try await exercise(
            .exportTo,
            value: .object(["ok": true, "status": 200, "bytes": 1024, "mime": "image/png", "width": 20, "height": 15, "etag": "\"abc\""])
        ) { handle in
            _ = try await handle.exportTo(.presigned(
                url: URL(string: "https://bucket.example/key?sig=1")!,
                method: .put,
                headers: ["content-type": "image/png"],
                format: .png
            ))
        }
        XCTAssertEqual(call.args[0]["url"]?.stringValue, "https://bucket.example/key?sig=1")
        XCTAssertEqual(call.args[0]["method"]?.stringValue, "PUT")
        XCTAssertEqual(call.args[0]["format"]?.stringValue, "png")
        XCTAssertEqual(call.args[0]["headers"]?["content-type"]?.stringValue, "image/png")
        XCTAssertNil(call.args[0]["destinationId"], "a presigned target must not also name a destination")
    }

    func testExportToSavedDestinationEncodingAndResult() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.exportTo(.savedDestination(id: "sd_123", format: .webp)) }
        let call = try await transport.awaitCall(.exportTo)
        XCTAssertEqual(call.args[0]["destinationId"]?.stringValue, "sd_123")
        XCTAssertEqual(call.args[0]["format"]?.stringValue, "webp")
        XCTAssertNil(call.args[0]["url"])
        transport.pushResult(id: call.id, value: .object([
            "ok": true, "status": 200, "bytes": 4096, "mime": "image/webp",
            "width": 20, "height": 15, "etag": .null, "key": "2026/09/13/x.webp", "bucket": "shots",
        ]))
        let result = try await task.value
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.key, "2026/09/13/x.webp")
        XCTAssertEqual(result.bucket, "shots")
        XCTAssertNil(result.etag)
    }

    func testExportToSurfacesTheBucketStatus() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.exportTo(.presigned(url: URL(string: "https://bucket.example/k")!)) }
        let call = try await transport.awaitCall(.exportTo)
        transport.pushFailure(id: call.id, code: "upload_failed", message: "the bucket answered 403", details: ["status": 403])
        do {
            _ = try await task.value
            XCTFail("expected upload_failed")
        } catch let error as SnapneditError {
            XCTAssertEqual(error.code, .uploadFailed)
            XCTAssertEqual(error.uploadStatus, 403)
            XCTAssertEqual(error.detailsAny?["status"] as? Double, 403)
        }
    }

    func testListDestinations() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.listDestinations() }
        let call = try await transport.awaitCall(.listDestinations)
        transport.pushResult(id: call.id, value: .array([
            .object(["id": "sd_1", "name": "Shots", "provider": "cloudflare-r2", "bucket": "shots", "isDefault": true]),
        ]))
        let destinations = try await task.value
        XCTAssertEqual(destinations.count, 1)
        XCTAssertEqual(destinations[0].provider, .cloudflareR2)
        XCTAssertTrue(destinations[0].isDefault)
    }

    // MARK: - Operations

    func testRunEncodesOperationAndParams() async throws {
        let call = try await exercise(.run) { try await $0.run(.resizeImage, params: ["width": 20]) }
        XCTAssertEqual(call.args[0].stringValue, "resize-image")
        XCTAssertEqual(call.args[1]["width"]?.intValue, 20)
    }

    func testRunOmitsEmptyParams() async throws {
        let call = try await exercise(.run) { _ = try await $0.run(.removeBackground) }
        XCTAssertEqual(call.args.count, 1)
    }

    /// `run` resolves with nothing on the wire, so the job id, the credits and
    /// the duration have to come from the `job` events the frame emitted while
    /// the call was in flight.
    func testRunReportsTheJobEventItObserved() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.run(.upscale) }
        let call = try await transport.awaitCall(.run)
        transport.pushEvent("job", ["operation": "upscale", "status": "started", "credits": 2])
        transport.pushEvent("job", ["operation": "upscale", "status": "succeeded", "credits": 2, "jobId": "job_9", "durationMs": 842])
        transport.pushResult(id: call.id)
        let result = try await task.value
        XCTAssertEqual(result.jobId, "job_9")
        XCTAssertEqual(result.credits, 2)
        XCTAssertEqual(result.durationMs, 842)
    }

    /// A job event from a PREVIOUS run must not be reported as this one's.
    func testRunIgnoresAStaleJobEvent() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        transport.pushEvent("job", ["operation": "upscale", "status": "succeeded", "credits": 2, "jobId": "job_old"])
        await FakeTransport.settle()

        let task = Task { try await handle.run(.upscale) }
        let call = try await transport.awaitCall(.run)
        transport.pushResult(id: call.id)
        let result = try await task.value
        XCTAssertNil(result.jobId, "a cache hit reports no job, not the previous run's")
    }

    func testUntypedParamsAreValidated() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        await assertThrows(.invalidInput) {
            _ = try await handle.run(.resizeImage, params: ["callback": { () -> Void in }] as [String: Any])
        }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testOpenToolTakesAnOperationOrARail() async throws {
        let byOperation = try await exercise(.openTool) { try await $0.openTool(.magicEraser) }
        XCTAssertEqual(byOperation.args[0].stringValue, "magic-eraser")
        let byRail = try await exercise(.openTool) { try await $0.openTool(rail: .uploads) }
        XCTAssertEqual(byRail.args[0].stringValue, "uploads")
    }

    // MARK: - History, selection, state

    func testUndoRedo() async throws {
        let undo = try await exercise(.undo) { try await $0.undo() }
        XCTAssertEqual(undo.args.count, 0)
        let redo = try await exercise(.redo) { try await $0.redo() }
        XCTAssertEqual(redo.args.count, 0)
    }

    func testSelect() async throws {
        let call = try await exercise(.select) { try await $0.select(["a", "b"]) }
        XCTAssertEqual(call.args[0].arrayValue?.compactMap(\.stringValue), ["a", "b"])
    }

    // MARK: - Appearance

    /// A `[SnapneditThemeColor: String]` would encode as a flat ARRAY through
    /// Codable's default synthesis for non-String-keyed dictionaries. The frame
    /// wants an object.
    func testThemeColorsEncodeAsAnObject() async throws {
        let call = try await exercise(.setTheme) { handle in
            try await handle.setTheme(SnapneditTheme(mode: .dark, colors: [.accent: "#f50", .bg: "#000"], radius: 12))
        }
        XCTAssertEqual(call.args[0]["mode"]?.stringValue, "dark")
        XCTAssertEqual(call.args[0]["colors"]?["accent"]?.stringValue, "#f50")
        XCTAssertEqual(call.args[0]["colors"]?["bg"]?.stringValue, "#000")
        XCTAssertEqual(call.args[0]["radius"]?.intValue, 12)
        XCTAssertNil(call.args[0]["css"])
    }

    func testFeaturesEncodeOperationIdsAsStrings() async throws {
        let call = try await exercise(.setFeatures) { handle in
            try await handle.setFeatures(SnapneditFeatures(
                tools: [.uploads, .text],
                aiOperations: [.removeBackground, .upscale],
                panels: [.layers],
                collab: false,
                export: .init(formats: [.png, .webp], mode: .callback)
            ))
        }
        XCTAssertEqual(call.args[0]["tools"]?.arrayValue?.compactMap(\.stringValue), ["uploads", "text"])
        XCTAssertEqual(call.args[0]["aiOperations"]?.arrayValue?.compactMap(\.stringValue), ["remove-background", "upscale"])
        XCTAssertEqual(call.args[0]["export"]?["formats"]?.arrayValue?.compactMap(\.stringValue), ["png", "webp"])
        XCTAssertEqual(call.args[0]["export"]?["mode"]?.stringValue, "callback")
        XCTAssertEqual(call.args[0]["collab"]?.boolValue, false)
    }

    func testSetLocale() async throws {
        let locale = try await exercise(.setLocale) { try await $0.setLocale("fr") }
        XCTAssertEqual(locale.args[0].stringValue, "fr")
    }

    // MARK: - Token refresh

    func testRefreshTokenIsSentImmediatelyNotQueued() throws {
        let (transport, handle) = makeHandle()
        // Deliberately BEFORE ready: a token-expiring answer must not be
        // gated behind a boot that the expiry itself may be blocking.
        try handle.refreshToken("eyJnew")
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertTrue(transport.sent[0].contains("refresh-token"))
    }

    // MARK: - Version skew

    /// A NEWER wrapper against an OLDER frame: the frame answers
    /// `invalid_input: unknown method X`, which must surface as `unsupported`
    /// so the host does not go hunting for a bad argument.
    func testUnknownMethodBecomesUnsupported() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.listDestinations() }
        let call = try await transport.awaitCall(.listDestinations)
        transport.pushFailure(id: call.id, code: "invalid_input", message: "unknown method listDestinations")
        await assertThrows(.unsupported) { _ = try await task.value }
    }

    /// A genuine `invalid_input` must NOT be rewritten.
    func testOrdinaryInvalidInputIsPreserved() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.loadImage(url: URL(string: "https://snapnedit.com/x.png")!) }
        let call = try await transport.awaitCall(.loadImage)
        transport.pushFailure(id: call.id, code: "invalid_input", message: "src must not be on the editor's own origin")
        await assertThrows(.invalidInput) { try await task.value }
    }

    /// A method a newer frame added can still be reached, without waiting for
    /// a wrapper release.
    func testRawCallEscapeHatch() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.call(SnapneditMethod("somethingNew"), [.string("x")]) }
        let call = try await transport.awaitCall(SnapneditMethod("somethingNew"))
        transport.pushResult(id: call.id, value: .string("done"))
        let raw = try await task.value
        XCTAssertEqual(raw.stringValue, "done")
    }
}
