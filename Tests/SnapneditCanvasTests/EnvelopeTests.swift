import Foundation
import XCTest
@testable import SnapneditCanvas

/// The wire format itself: what a `call` looks like on the way out, and what
/// the four inbound shapes decode to on the way in.
final class EnvelopeTests: XCTestCase {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(json.data(using: .utf8)))
    }

    func testCallEnvelopeShape() throws {
        let json = try SnapneditOutboundEnvelope
            .call(id: "abc123", method: .run, args: [.string("resize-image"), .object(["width": 20])])
            .json()
        let value = try decode(json)
        XCTAssertEqual(value["snapnedit"]?.intValue, 1)
        XCTAssertEqual(value["type"]?.stringValue, "call")
        XCTAssertEqual(value["id"]?.stringValue, "abc123")
        XCTAssertEqual(value["payload"]?["method"]?.stringValue, "run")
        XCTAssertEqual(value["payload"]?["args"]?[0]?.stringValue, "resize-image")
        XCTAssertEqual(value["payload"]?["args"]?[1]?["width"]?.intValue, 20)
    }

    func testRefreshTokenEnvelopeShape() throws {
        let value = try decode(try SnapneditOutboundEnvelope.refreshToken("eyJhbGci").json())
        XCTAssertEqual(value["snapnedit"]?.intValue, 1)
        XCTAssertEqual(value["type"]?.stringValue, "refresh-token")
        XCTAssertEqual(value["payload"]?["token"]?.stringValue, "eyJhbGci")
    }

    func testDecodesReadyForInit() throws {
        let envelope = try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":1,"type":"ready-for-init"}"#)
        XCTAssertEqual(envelope, .readyForInit)
    }

    func testDecodesEvent() throws {
        let envelope = try SnapneditInboundEnvelope.decode(
            json: #"{"snapnedit":1,"type":"event","payload":{"name":"ready","data":{"version":"0.3.0"}}}"#
        )
        guard case .event(let name, let data) = envelope else { return XCTFail("expected an event, got \(envelope)") }
        XCTAssertEqual(name, .ready)
        XCTAssertEqual(data["version"]?.stringValue, "0.3.0")
    }

    /// An event with no `data` at all is still an event — the `close` event has
    /// an empty payload and must not be dropped.
    func testDecodesEventWithoutData() throws {
        let envelope = try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":1,"type":"event","payload":{"name":"close"}}"#)
        guard case .event(let name, let data) = envelope else { return XCTFail("expected an event") }
        XCTAssertEqual(name, .close)
        XCTAssertEqual(data, .object([:]))
    }

    func testDecodesSuccessResult() throws {
        let envelope = try SnapneditInboundEnvelope.decode(
            json: #"{"snapnedit":1,"type":"result","id":"7","payload":{"ok":true,"value":{"width":20}}}"#
        )
        guard case .result(let id, .success(let value)) = envelope else { return XCTFail("expected a success result") }
        XCTAssertEqual(id, "7")
        XCTAssertEqual(value["width"]?.intValue, 20)
    }

    func testDecodesFailureResultWithDetails() throws {
        let envelope = try SnapneditInboundEnvelope.decode(
            json: #"{"snapnedit":1,"type":"result","id":"7","payload":{"ok":false,"error":{"code":"upload_failed","message":"403","details":{"status":403}}}}"#
        )
        guard case .result(_, .failure(let error)) = envelope else { return XCTFail("expected a failure result") }
        XCTAssertEqual(error.code, .uploadFailed)
        XCTAssertEqual(error.uploadStatus, 403)
    }

    /// A `null` value is a real answer (every void method returns one) and must
    /// not be mistaken for a missing one.
    func testDecodesNullValue() throws {
        let envelope = try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":1,"type":"result","id":"1","payload":{"ok":true,"value":null}}"#)
        guard case .result(_, .success(let value)) = envelope else { return XCTFail("expected a success result") }
        XCTAssertTrue(value.isNull)
    }

    func testRejectsNonJSON() {
        XCTAssertThrowsError(try SnapneditInboundEnvelope.decode(json: "not json {")) { error in
            XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
        }
    }

    /// A message without `snapnedit: 1` is not ours. Anything the webview's
    /// page scripts happen to post must not be parsed as a protocol message.
    func testRejectsForeignMessage() {
        XCTAssertThrowsError(try SnapneditInboundEnvelope.decode(json: #"{"type":"result","id":"1"}"#)) { error in
            XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
        }
        XCTAssertThrowsError(try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":2,"type":"result","id":"1"}"#)) { error in
            XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
        }
    }

    func testRejectsUnknownEnvelopeType() {
        XCTAssertThrowsError(try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":1,"type":"telemetry"}"#)) { error in
            XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
        }
    }

    func testRejectsResultWithoutID() {
        XCTAssertThrowsError(try SnapneditInboundEnvelope.decode(json: #"{"snapnedit":1,"type":"result","payload":{"ok":true}}"#)) { error in
            XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
        }
    }
}
