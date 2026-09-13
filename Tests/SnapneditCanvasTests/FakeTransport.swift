import Foundation
import XCTest
@testable import SnapneditCanvas

/// A ``SnapneditTransport`` with no WKWebView behind it: what the shell sends
/// is recorded, and what the frame "replies" is whatever the test pushes.
///
/// Everything the protocol layer does — envelope shapes, id matching,
/// timeouts, the ready gate, blob decoding, error mapping — is observable
/// through this, which is why none of it needs a browser to be tested.
@MainActor
final class FakeTransport: SnapneditTransport {
    /// Every JSON string handed to the frame, in order.
    private(set) var sent: [String] = []
    private(set) var isTornDown = false
    var onMessage: (@MainActor (String) -> Void)?

    /// Called for each outbound message, before it is recorded — lets a test
    /// answer synchronously, the way a very fast frame would.
    var sendHook: (@MainActor (String) -> Void)?

    func send(_ json: String) {
        sent.append(json)
        sendHook?(json)
    }

    func teardown() {
        isTornDown = true
        onMessage = nil
    }

    // MARK: - What the shell sent, decoded

    struct SentCall {
        let id: String
        let method: String
        let args: [JSONValue]
    }

    /// Every `call` envelope the shell produced, parsed.
    var calls: [SentCall] {
        sent.compactMap { json in
            guard let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  value["type"]?.stringValue == "call",
                  let id = value["id"]?.stringValue,
                  let method = value["payload"]?["method"]?.stringValue
            else { return nil }
            return SentCall(id: id, method: method, args: value["payload"]?["args"]?.arrayValue ?? [])
        }
    }

    var methodNames: [String] { calls.map(\.method) }

    /// The last call for `method`, or `nil`.
    func lastCall(_ method: SnapneditMethod) -> SentCall? {
        calls.last { $0.method == method.rawValue }
    }

    // MARK: - What the frame replies

    private func push(_ value: JSONValue) {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else {
            return XCTFail("could not encode a fake frame message")
        }
        onMessage?(json)
    }

    /// Pushes a raw string, valid or not — for the malformed-input tests.
    func pushRaw(_ json: String) { onMessage?(json) }

    func pushReadyForInit() {
        push(.object(["snapnedit": 1, "type": "ready-for-init"]))
    }

    func pushEvent(_ name: String, _ data: [String: JSONValue] = [:]) {
        push(.object([
            "snapnedit": 1,
            "type": "event",
            "payload": .object(["name": .string(name), "data": .object(data)]),
        ]))
    }

    func pushReady(version: String = "0.3.0") {
        pushEvent("ready", ["version": .string(version)])
    }

    func pushResult(id: String, value: JSONValue = .null) {
        push(.object([
            "snapnedit": 1,
            "type": "result",
            "id": .string(id),
            "payload": .object(["ok": true, "value": value]),
        ]))
    }

    func pushFailure(id: String, code: String, message: String, details: [String: JSONValue]? = nil) {
        var error: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let details { error["details"] = .object(details) }
        push(.object([
            "snapnedit": 1,
            "type": "result",
            "id": .string(id),
            "payload": .object(["ok": false, "error": .object(error)]),
        ]))
    }

    // MARK: - Waiting

    /// Lets enqueued main-actor work run. Everything here is single-threaded,
    /// so a handful of yields is enough to reach the next suspension point.
    static func settle(_ times: Int = 12) async {
        for _ in 0..<times { await Task.yield() }
    }

    /// Waits until `count` calls have been sent, then returns the last one.
    @discardableResult
    func awaitCall(_ method: SnapneditMethod, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) async throws -> SentCall {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let call = lastCall(method) { return call }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("no `\(method.rawValue)` call reached the transport", file: file, line: line)
        throw SnapneditError(code: .timeout, message: "no \(method.rawValue) call")
    }
}

/// Builds a ready-gated handle over a fake transport.
///
/// The deadlines are generous rather than tight: every test that is ABOUT a
/// deadline passes its own (sub-second) values, and everything else must not
/// be able to trip one just because the machine was busy compiling a moment
/// ago. A 2s boot budget here made the suite flaky on a cold run.
@MainActor
func makeHandle(timeouts: SnapneditTimeouts = SnapneditTimeouts(call: 60, longRunningCall: 60, ready: 60)) -> (FakeTransport, SnapneditEditorHandle) {
    let transport = FakeTransport()
    return (transport, SnapneditEditorHandle(transport: transport, timeouts: timeouts))
}

/// Fails unless `body` throws a ``SnapneditError`` with `code`.
@MainActor
func assertThrows(
    _ code: SnapneditErrorCode,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected `\(code.rawValue)`, but nothing was thrown", file: file, line: line)
    } catch let error as SnapneditError {
        XCTAssertEqual(error.code, code, "wrong error code: \(error)", file: file, line: line)
    } catch {
        XCTFail("expected a SnapneditError `\(code.rawValue)`, got \(error)", file: file, line: line)
    }
}
