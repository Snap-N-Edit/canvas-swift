import Foundation
import XCTest
@testable import SnapneditCanvas

/// The handle's own machinery: id matching, the ready gate, timeouts, teardown.
@MainActor
final class HandleTests: XCTestCase {
    // MARK: - Ready gating

    /// Calls issued before `ready` must be QUEUED, not refused — a shell that
    /// drives the editor straight after `load()` is the normal case, and
    /// forcing every host to write its own gate would be a worse API.
    func testCallsBeforeReadyAreQueuedNotSent() async throws {
        let (transport, handle) = makeHandle()
        let task = Task { try await handle.undo() }
        await FakeTransport.settle()
        XCTAssertTrue(transport.sent.isEmpty, "a call before `ready` must not reach the frame")

        transport.pushReady()
        await FakeTransport.settle()
        let call = try await transport.awaitCall(.undo)
        transport.pushResult(id: call.id)
        try await task.value
    }

    /// And they must be flushed in the order they were issued: the second
    /// `loadImage` winning a race with the first would silently produce the
    /// wrong document.
    func testQueuedCallsFlushInOrder() async throws {
        let (transport, handle) = makeHandle()
        let first = Task { try await handle.undo() }
        await FakeTransport.settle()
        let second = Task { try await handle.redo() }
        await FakeTransport.settle()
        let third = Task { _ = try await handle.getDocument() }
        await FakeTransport.settle()
        XCTAssertTrue(transport.sent.isEmpty)

        transport.pushReady()
        await FakeTransport.settle(40)
        XCTAssertEqual(transport.methodNames, ["undo", "redo", "getDocument"])

        for call in transport.calls { transport.pushResult(id: call.id, value: .object([:])) }
        try await first.value
        try await second.value
        try await third.value
    }

    /// A queued call's deadline must start when the envelope is actually SENT,
    /// not when the call was issued — otherwise a 30s call issued against a
    /// 40s boot times out before the editor has drawn a pixel.
    func testAQueuedCallsDeadlineStartsAtSendNotAtIssue() async throws {
        let (transport, handle) = makeHandle(timeouts: SnapneditTimeouts(call: 0.4, longRunningCall: 0.4, ready: 5))
        let task = Task { try await handle.undo() }
        await FakeTransport.settle()
        // Longer than the CALL deadline, entirely inside the boot.
        try await Task.sleep(nanoseconds: 700_000_000)
        transport.pushReady()
        let call = try await transport.awaitCall(.undo)
        transport.pushResult(id: call.id)
        try await task.value
    }

    func testReadyExposesVersion() async throws {
        let (transport, handle) = makeHandle()
        XCTAssertFalse(handle.isReady)
        transport.pushReady(version: "0.3.1")
        await FakeTransport.settle()
        XCTAssertTrue(handle.isReady)
        XCTAssertEqual(handle.frameVersion, "0.3.1")
    }

    /// An `error` BEFORE `ready` is a fatal boot failure — a refused key or app
    /// id — and every queued call has to learn about it rather than sit until
    /// its own deadline.
    func testErrorBeforeReadyFailsTheBootAndEveryQueuedCall() async throws {
        let (transport, handle) = makeHandle()
        let queued = Task { try await handle.undo() }
        await FakeTransport.settle()
        transport.pushEvent("error", ["code": "origin_denied", "message": "native:e2e.app is not allowed"])
        await FakeTransport.settle()

        await assertThrows(.originDenied) { try await queued.value }
        // And so must every LATER call: the session is dead, not merely slow.
        await assertThrows(.originDenied) { try await handle.redo() }
        XCTAssertTrue(transport.sent.isEmpty)
    }

    /// After `ready`, an `error` event is informational: it must not poison a
    /// working session.
    func testErrorAfterReadyIsInformational() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        transport.pushEvent("error", ["code": "rate_limited", "message": "slow down"])
        await FakeTransport.settle()

        let task = Task { try await handle.undo() }
        let call = try await transport.awaitCall(.undo)
        transport.pushResult(id: call.id)
        try await task.value
    }

    func testBootTimesOut() async {
        let (_, handle) = makeHandle(timeouts: SnapneditTimeouts(call: 1, longRunningCall: 1, ready: 0.15))
        await assertThrows(.timeout) { try await handle.waitUntilReady() }
    }

    // MARK: - Id matching

    /// Two calls in flight at once, answered out of order, must each get their
    /// own answer.
    func testResultsAreMatchedByIDNotByArrival() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()

        let document = Task { try await handle.getDocument() }
        let state = Task { try await handle.getState() }
        await FakeTransport.settle(30)

        let documentCall = try XCTUnwrap(transport.lastCall(.getDocument))
        let stateCall = try XCTUnwrap(transport.lastCall(.getState))
        XCTAssertNotEqual(documentCall.id, stateCall.id, "every call needs its own id")

        // Answer the SECOND one first.
        transport.pushResult(id: stateCall.id, value: .object([
            "canUndo": true, "canRedo": false, "selection": .array([]), "page": 0,
            "pageCount": 1, "width": 20, "height": 15, "dirty": true, "busy": false,
        ]))
        transport.pushResult(id: documentCall.id, value: .object(["width": 640]))

        let resolvedState = try await state.value
        XCTAssertEqual(resolvedState.width, 20)
        XCTAssertTrue(resolvedState.canUndo)
        let resolvedDocument = try await document.value
        XCTAssertEqual(resolvedDocument["width"]?.intValue, 640)
    }

    /// A `result` for an id nobody is waiting on (a late answer after a
    /// timeout) must be ignored, not crash.
    func testUnknownResultIDIsIgnored() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        transport.pushResult(id: "not-a-call-we-made", value: .string("x"))
        await FakeTransport.settle()
        XCTAssertTrue(handle.isReady)
    }

    // MARK: - Timeouts

    func testOrdinaryCallTimesOut() async throws {
        let (transport, handle) = makeHandle(timeouts: SnapneditTimeouts(call: 0.15, longRunningCall: 5, ready: 2))
        transport.pushReady()
        await FakeTransport.settle()
        await assertThrows(.timeout) { _ = try await handle.getDocument() }
    }

    /// A long-running method gets the long deadline, so an AI job that takes
    /// 40s is not killed by the 30s ordinary budget.
    func testLongRunningCallUsesTheLongerDeadline() async throws {
        let (transport, handle) = makeHandle(timeouts: SnapneditTimeouts(call: 0.15, longRunningCall: 3, ready: 2))
        transport.pushReady()
        await FakeTransport.settle()

        let task = Task { try await handle.run(.resizeImage, params: ["width": 20]) }
        let call = try await transport.awaitCall(.run)
        // Well past the ORDINARY deadline...
        try await Task.sleep(nanoseconds: 400_000_000)
        transport.pushResult(id: call.id)
        // ...and it still resolves.
        let result = try await task.value
        XCTAssertEqual(result.operation, .resizeImage)
    }

    func testEveryLongRunningMethodFromProtocolJSONIsFlagged() {
        XCTAssertEqual(
            Set(SnapneditMethod.longRunning.map(\.rawValue)),
            ["loadImage", "addImage", "export", "exportTo", "run"]
        )
        for method in SnapneditMethod.all where !SnapneditMethod.longRunning.contains(method) {
            XCTAssertFalse(method.isLongRunning, "\(method.rawValue) should use the ordinary deadline")
        }
    }

    // MARK: - Teardown

    func testDestroyFailsPendingCallsAndTearsDownTheTransport() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()

        let task = Task { try await handle.getDocument() }
        _ = try await transport.awaitCall(.getDocument)
        handle.destroy()

        await assertThrows(.destroyed) { _ = try await task.value }
        XCTAssertTrue(transport.isTornDown)
        XCTAssertTrue(handle.isDestroyed)
        await assertThrows(.destroyed) { try await handle.undo() }
    }

    func testDestroyBeforeReadyFailsWaiters() async throws {
        let (_, handle) = makeHandle()
        let task = Task { try await handle.waitUntilReady() }
        await FakeTransport.settle()
        handle.destroy()
        await assertThrows(.destroyed) { try await task.value }
    }

    func testDestroyIsIdempotent() async {
        let (_, handle) = makeHandle()
        handle.destroy()
        handle.destroy()
        XCTAssertTrue(handle.isDestroyed)
    }

    // MARK: - Malformed inbound

    /// A frame (or shell) with a serialization bug must produce a visible
    /// `error` event, never silence.
    func testMalformedInboundBecomesAnErrorEvent() async throws {
        let (transport, handle) = makeHandle()
        var seen: [SnapneditCanvasEvent] = []
        handle.onEvent = { seen.append($0) }
        transport.pushRaw("}{ not json")
        await FakeTransport.settle()
        guard case .error(let error) = seen.first else { return XCTFail("expected an error event, got \(seen)") }
        XCTAssertEqual(error.code, .invalidInput)
    }

    /// `ready-for-init` is a no-op on the native transport: the frame builds
    /// its own config from the URL, so a shell that answered it would be
    /// sending an `init` the frame refuses.
    func testReadyForInitIsNotAnswered() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReadyForInit()
        await FakeTransport.settle()
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertFalse(handle.isReady)
    }
}
