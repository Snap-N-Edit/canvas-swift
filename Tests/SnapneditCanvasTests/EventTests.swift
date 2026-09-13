import Foundation
import XCTest
@testable import SnapneditCanvas

/// Event decoding and fan-out.
@MainActor
final class EventTests: XCTestCase {
    private func decoded(_ name: String, _ data: [String: JSONValue]) async -> [SnapneditCanvasEvent] {
        let (transport, handle) = makeHandle()
        var seen: [SnapneditCanvasEvent] = []
        handle.onEvent = { seen.append($0) }
        transport.pushEvent(name, data)
        await FakeTransport.settle()
        return seen
    }

    func testReady() async {
        let events = await decoded("ready", ["version": "0.3.0"])
        guard case .ready(let version) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(version, "0.3.0")
    }

    func testChange() async {
        let events = await decoded("change", ["dirty": true, "pageCount": 3])
        guard case .change(let dirty, let pages) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(dirty)
        XCTAssertEqual(pages, 3)
    }

    func testSelection() async {
        let events = await decoded("selection", ["ids": .array(["a", "b"]), "kind": "image"])
        guard case .selection(let ids, let kind) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(kind, "image")
    }

    /// `kind` is nullable, and a cleared selection sends it as JSON `null`.
    func testSelectionWithNullKind() async {
        let events = await decoded("selection", ["ids": .array([]), "kind": .null])
        guard case .selection(let ids, let kind) = events.first else { return XCTFail("\(events)") }
        XCTAssertTrue(ids.isEmpty)
        XCTAssertNil(kind)
    }

    func testJobStartedAndFailed() async {
        let started = await decoded("job", ["operation": "upscale", "status": "started", "credits": 2])
        guard case .job(let a) = started.first else { return XCTFail("\(started)") }
        XCTAssertEqual(a.status, .started)
        XCTAssertEqual(a.operation, .upscale)
        XCTAssertEqual(a.credits, 2)

        let failed = await decoded("job", [
            "operation": "magic-eraser", "status": "failed", "credits": 1,
            "error": .object(["code": "mask_required", "message": "paint a mask first"]),
            "endUserId": "user_7",
        ])
        guard case .job(let b) = failed.first else { return XCTFail("\(failed)") }
        XCTAssertEqual(b.status, .failed)
        XCTAssertEqual(b.error?.code, .maskRequired)
        XCTAssertEqual(b.endUserId, "user_7")
    }

    /// The frame's own Export menu can produce an animated GIF — a format no
    /// host can request, so it needs its own enum case rather than being
    /// dropped.
    func testExportEventCarriesTheDecodedBytesIncludingGIF() async {
        let bytes = Data([0x47, 0x49, 0x46, 0x38])
        let events = await decoded("export", [
            "format": "gif",
            "blob": .object(["dataUrl": .string(SnapneditDataURL.encode(bytes, mime: "image/gif")), "mime": "image/gif", "bytes": 4]),
            "width": 320,
            "height": 240,
        ])
        guard case .export(let export) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(export.format, .gif)
        XCTAssertNil(export.format.requestable, "gif is not requestable")
        XCTAssertEqual(export.result.data, bytes)
        XCTAssertEqual(export.result.width, 320)
    }

    func testSaveEventCarriesDocumentAndPages() async {
        let events = await decoded("save", ["document": .object(["width": 100]), "pages": .array([.object(["width": 100])])])
        guard case .save(let save) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(save.document["width"]?.intValue, 100)
        XCTAssertEqual(save.pages.count, 1)
    }

    func testCloseEvent() async {
        let events = await decoded("close", [:])
        guard case .close = events.first else { return XCTFail("\(events)") }
    }

    func testErrorEvent() async {
        let events = await decoded("error", ["code": "token_expired", "message": "the session token ran out"])
        guard case .error(let error) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(error.code, .tokenExpired)
    }

    func testTokenExpiringParsesTheTimestamp() async throws {
        let events = await decoded("token-expiring", ["expiresAt": "2026-09-13T10:20:30Z"])
        guard case .tokenExpiring(let date, let raw) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(raw, "2026-09-13T10:20:30Z")
        XCTAssertEqual(try XCTUnwrap(date).timeIntervalSince1970, 1_789_294_830, accuracy: 1)
    }

    func testTokenExpiringWithFractionalSeconds() async {
        let events = await decoded("token-expiring", ["expiresAt": "2026-09-13T10:20:30.500Z"])
        guard case .tokenExpiring(let date, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertNotNil(date)
    }

    /// An event a newer frame added must arrive intact, not vanish.
    func testUnknownEventIsPreserved() async {
        let events = await decoded("telemetry", ["foo": "bar"])
        guard case .unknown(let name, let data) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(name, "telemetry")
        XCTAssertEqual(data["foo"]?.stringValue, "bar")
    }

    /// A known event whose payload does not match this release's shape must
    /// degrade to `unknown` rather than be silently swallowed.
    func testMalformedKnownEventDegradesToUnknown() async {
        let events = await decoded("job", ["operation": "upscale"])
        guard case .unknown(let name, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(name, "job")
    }

    func testEveryEventNameFromProtocolJSONIsModelled() {
        XCTAssertEqual(
            SnapneditEventName.all.map(\.rawValue),
            ["ready", "change", "selection", "job", "export", "save", "close", "error", "token-expiring"]
        )
        for name in SnapneditEventName.all {
            let event = SnapneditCanvasEvent.decode(name: name, data: .object([:]))
            if case .unknown = event, name != .job, name != .export {
                XCTFail("`\(name.rawValue)` has no modelled case")
            }
            XCTAssertEqual(event.name.rawValue, name.rawValue)
        }
    }

    // MARK: - Fan-out

    func testAsyncStreamDeliversEvents() async throws {
        let (transport, handle) = makeHandle()
        let stream = handle.events
        let collected = Task {
            var out: [SnapneditCanvasEvent] = []
            for await event in stream {
                out.append(event)
                if out.count == 2 { break }
            }
            return out
        }
        await FakeTransport.settle()
        transport.pushReady()
        transport.pushEvent("change", ["dirty": true, "pageCount": 1])
        let events = await collected.value
        XCTAssertEqual(events.count, 2)
        guard case .ready = events[0] else { return XCTFail("\(events)") }
        guard case .change = events[1] else { return XCTFail("\(events)") }
    }

    /// `ready` is one-shot, so a stream opened after boot must be given it
    /// anyway — otherwise a listener attached from a later screen waits forever.
    func testReadyIsReplayedToALateSubscriber() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady(version: "0.3.0")
        await FakeTransport.settle()

        var iterator = handle.events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .ready(let version) = first else { return XCTFail("\(String(describing: first))") }
        XCTAssertEqual(version, "0.3.0")
    }

    func testSeveralStreamsEachSeeEveryEvent() async throws {
        let (transport, handle) = makeHandle()
        var a = handle.events.makeAsyncIterator()
        var b = handle.events.makeAsyncIterator()
        await FakeTransport.settle()
        transport.pushEvent("close")
        guard case .close = await a.next() else { return XCTFail("stream a missed it") }
        guard case .close = await b.next() else { return XCTFail("stream b missed it") }
    }

    func testDestroyFinishesTheStreams() async throws {
        let (_, handle) = makeHandle()
        let stream = handle.events
        let drained = Task {
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        await FakeTransport.settle()
        handle.destroy()
        let count = await drained.value
        XCTAssertEqual(count, 0)
    }

    func testDelegateReceivesReadyAndEvents() async throws {
        final class Recorder: SnapneditCanvasDelegate {
            var events: [SnapneditCanvasEvent] = []
            var readyVersions: [String] = []
            func snapneditCanvas(_ handle: SnapneditEditorHandle, didEmit event: SnapneditCanvasEvent) { events.append(event) }
            func snapneditCanvasDidBecomeReady(_ handle: SnapneditEditorHandle, version: String) { readyVersions.append(version) }
        }
        let (transport, handle) = makeHandle()
        let recorder = Recorder()
        handle.delegate = recorder
        transport.pushReady(version: "0.3.0")
        transport.pushEvent("close")
        await FakeTransport.settle()
        XCTAssertEqual(recorder.readyVersions, ["0.3.0"])
        XCTAssertEqual(recorder.events.count, 2)
    }
}
