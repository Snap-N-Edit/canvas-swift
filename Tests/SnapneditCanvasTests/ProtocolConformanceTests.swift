import Foundation
import XCTest
@testable import SnapneditCanvas

/// The wrapper against the contract itself.
///
/// `Resources/protocol.json` is a verbatim copy of `packages/embed/protocol.json`
/// from the snapnedit monorepo, refreshed whenever this package is released.
/// Every method, event and error code it lists must be modelled here — which is
/// what stops the Swift surface quietly falling behind the editor.
final class ProtocolConformanceTests: XCTestCase {
    private func contract() throws -> JSONValue {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "protocol", withExtension: "json"),
            "protocol.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    func testProtocolVersionMatches() throws {
        XCTAssertEqual(try contract()["version"]?.intValue, SnapneditProtocol.version)
    }

    func testEveryMethodIsModelled() throws {
        let methods = try XCTUnwrap(contract()["methods"]?.objectValue)
        XCTAssertEqual(Set(methods.keys), Set(SnapneditMethod.all.map(\.rawValue)))
    }

    /// The `longRunning` flag decides whether a call gets 30s or 180s. Getting
    /// it wrong for `run` would kill every AI job that takes over half a
    /// minute — the ordinary case.
    func testLongRunningFlagsMatch() throws {
        let methods = try XCTUnwrap(contract()["methods"]?.objectValue)
        for (name, spec) in methods {
            let expected = spec["longRunning"]?.boolValue ?? false
            XCTAssertEqual(SnapneditMethod(name).isLongRunning, expected, "`\(name)` longRunning mismatch")
        }
    }

    func testEveryEventIsModelled() throws {
        let events = try XCTUnwrap(contract()["events"]?.objectValue)
        XCTAssertEqual(Set(events.keys), Set(SnapneditEventName.all.map(\.rawValue)))
    }

    func testEveryErrorCodeIsModelled() throws {
        let codes = try XCTUnwrap(contract()["errorCodes"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertEqual(codes, SnapneditErrorCode.all.map(\.rawValue), "order and content must match protocol.json")
    }

    func testNativeConstantsMatch() throws {
        let native = try XCTUnwrap(contract()["native"])
        XCTAssertEqual(native["inbound"]?.stringValue, "\(SnapneditProtocol.bridgeGlobal).receive")
        XCTAssertEqual(native["channelName"]?.stringValue, SnapneditProtocol.channelName)
        XCTAssertEqual(native["payloadLimits"]?["recommendedMaxDataUrlBytes"]?.intValue, SnapneditLimits.recommendedMaxDataURLBytes)
        XCTAssertEqual(
            native["queryParams"]?["transport"]?["value"]?.stringValue,
            SnapneditProtocol.nativeTransport
        )
    }

    /// The channel this wrapper registers must be the FIRST one the frame
    /// probes for — `window.webkit.messageHandlers.snapnedit`.
    func testWKWebViewIsTheChannelWeRegister() throws {
        let channels = try XCTUnwrap(contract()["native"]?["outboundChannels"]?.arrayValue)
        let wk = try XCTUnwrap(channels.first { $0["id"]?.stringValue == "wkwebview" })
        XCTAssertEqual(
            wk["expression"]?.stringValue,
            "window.webkit.messageHandlers.\(SnapneditProtocol.channelName).postMessage(json)"
        )
    }

    func testBlobReplacementShapeMatches() throws {
        let replacement = try XCTUnwrap(contract()["native"]?["blobEncoding"]?["replacement"]?.objectValue)
        XCTAssertEqual(Set(replacement.keys), ["dataUrl", "mime", "bytes"])
    }

    /// `protocol.json`'s own frame URL template, rebuilt from the config.
    func testFrameURLMatchesTheDocumentedTemplate() throws {
        let template = try XCTUnwrap(contract()["native"]?["frameUrl"]?.stringValue)
        XCTAssertEqual(template, "https://snapnedit.com/embed?transport=native&origin=native:<app-id>&key=pk_live_...")
        let url = try SnapneditCanvasConfiguration(
            credential: .publishableKey("pk_live_...", appId: "<app-id>".replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: ""))
        ).frameURL()
        XCTAssertEqual(url.absoluteString, "https://snapnedit.com/embed?transport=native&origin=native:app-id&key=pk_live_...")
    }
}
