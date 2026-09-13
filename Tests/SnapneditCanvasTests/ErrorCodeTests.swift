import Foundation
import XCTest
@testable import SnapneditCanvas

/// Error mapping, for every code in `protocol.json`.
@MainActor
final class ErrorCodeTests: XCTestCase {
    /// EVERY code the frame can send must arrive as itself. A code that
    /// silently collapsed into `internal` would make a host's `switch`
    /// unreliable in exactly the cases it matters.
    func testEveryProtocolErrorCodeSurvivesARoundTrip() async throws {
        for code in SnapneditErrorCode.all {
            let (transport, handle) = makeHandle()
            transport.pushReady()
            await FakeTransport.settle()
            let task = Task { try await handle.undo() }
            let call = try await transport.awaitCall(.undo)
            transport.pushFailure(id: call.id, code: code.rawValue, message: "boom: \(code.rawValue)")
            do {
                try await task.value
                XCTFail("`\(code.rawValue)` did not throw")
            } catch let error as SnapneditError {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.message, "boom: \(code.rawValue)")
            }
            handle.destroy()
        }
    }

    /// And every one of them must also survive the `error` EVENT path, which
    /// is a different decoder.
    func testEveryProtocolErrorCodeSurvivesTheErrorEvent() async {
        for code in SnapneditErrorCode.all {
            let (transport, handle) = makeHandle()
            var seen: SnapneditError?
            handle.onEvent = { if case .error(let error) = $0 { seen = error } }
            // After ready, so the boot-failure path does not swallow it.
            transport.pushReady()
            await FakeTransport.settle()
            transport.pushEvent("error", ["code": .string(code.rawValue), "message": "boom"])
            await FakeTransport.settle()
            XCTAssertEqual(seen?.code, code)
            handle.destroy()
        }
    }

    func testAllListMatchesProtocolJSON() {
        XCTAssertEqual(SnapneditErrorCode.all.count, 22)
        XCTAssertEqual(
            SnapneditErrorCode.all.map(\.rawValue),
            [
                "invalid_input", "unsupported_mime", "too_large", "not_found", "input_fetch_failed",
                "provider_failed", "provider_exhausted", "rate_limited", "bot_check_failed",
                "unauthorized", "forbidden", "payment_required", "internal", "not_ready",
                "mask_required", "timeout", "origin_denied", "destroyed", "token_expired",
                "network_error", "upload_failed", "unsupported",
            ]
        )
        XCTAssertEqual(Set(SnapneditErrorCode.all).count, 22, "no duplicates")
    }

    /// A code this release has never heard of must arrive intact rather than
    /// failing to decode — the whole reason the type is a struct.
    func testUnknownCodeIsPreserved() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.undo() }
        let call = try await transport.awaitCall(.undo)
        transport.pushFailure(id: call.id, code: "quota_frozen", message: "new in a later release")
        do {
            try await task.value
            XCTFail("expected a throw")
        } catch let error as SnapneditError {
            XCTAssertEqual(error.code.rawValue, "quota_frozen")
            XCTAssertFalse(SnapneditErrorCode.all.contains(error.code))
        }
    }

    /// A failure with no `error` object at all is still a failure.
    func testFailureWithoutAnErrorObject() async throws {
        let (transport, handle) = makeHandle()
        transport.pushReady()
        await FakeTransport.settle()
        let task = Task { try await handle.undo() }
        let call = try await transport.awaitCall(.undo)
        transport.pushRaw(#"{"snapnedit":1,"type":"result","id":"\#(call.id)","payload":{"ok":false}}"#)
        await assertThrows(.internalError) { try await task.value }
    }

    func testCodesPatternMatchInASwitch() {
        let error = SnapneditError(code: .paymentRequired, message: "out of credits")
        switch error.code {
        case .paymentRequired: break
        default: XCTFail("static members must pattern-match")
        }
    }

    func testErrorDescriptionIncludesCodeAndMessage() {
        let error = SnapneditError(code: .maskRequired, message: "paint a mask")
        XCTAssertEqual(error.description, "mask_required: paint a mask")
        XCTAssertEqual(error.localizedDescription, "mask_required: paint a mask")
    }
}
