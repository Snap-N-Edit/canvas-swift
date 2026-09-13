import Foundation
import XCTest
@testable import SnapneditCanvas

/// The launch URL, the native app id rules, and the `data:` codec.
final class ConfigurationTests: XCTestCase {
    func testPublishableKeyURL() throws {
        let config = SnapneditCanvasConfiguration(credential: .publishableKey("pk_live_abc", appId: "com.acme.photos"))
        let url = try config.frameURL()
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "snapnedit.com")
        XCTAssertEqual(url.path, "/embed")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "transport" }?.value, "native")
        XCTAssertEqual(items.first { $0.name == "origin" }?.value, "native:com.acme.photos")
        XCTAssertEqual(items.first { $0.name == "key" }?.value, "pk_live_abc")
        XCTAssertNil(items.first { $0.name == "token" })
        XCTAssertNil(items.first { $0.name == "locale" })
    }

    func testTokenURLCarriesTokenNotKey() throws {
        let config = SnapneditCanvasConfiguration(
            baseURL: URL(string: "http://localhost:3000")!,
            credential: .token("eyJhbGci", appId: "e2e.app"),
            locale: "fr"
        )
        let items = URLComponents(url: try config.frameURL(), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "token" }?.value, "eyJhbGci")
        XCTAssertNil(items.first { $0.name == "key" })
        XCTAssertEqual(items.first { $0.name == "origin" }?.value, "native:e2e.app")
        XCTAssertEqual(items.first { $0.name == "locale" }?.value, "fr")
        XCTAssertEqual(try config.frameURL().absoluteString.hasPrefix("http://localhost:3000/embed?"), true)
    }

    /// A base URL with a path prefix (a reverse-proxied deployment) must keep it.
    func testBaseURLWithAPathPrefix() throws {
        let config = SnapneditCanvasConfiguration(
            baseURL: URL(string: "https://tools.example.com/snapnedit/")!,
            credential: .publishableKey("pk_live_abc", appId: "app")
        )
        XCTAssertEqual(try config.frameURL().path, "/snapnedit/embed")
    }

    /// The app id is written `native:<id>` in the dashboard, but a host that
    /// passes the bare id means the same thing.
    func testAppIdIsNormalizedAndLowerCased() throws {
        let bare = SnapneditCanvasConfiguration(credential: .publishableKey("pk", appId: "Com.Acme.Photos"))
        XCTAssertEqual(try bare.nativeOrigin(), "native:com.acme.photos")
        let prefixed = SnapneditCanvasConfiguration(credential: .publishableKey("pk", appId: "native:Com.Acme.Photos"))
        XCTAssertEqual(try prefixed.nativeOrigin(), "native:com.acme.photos")
    }

    /// A malformed id never reaches the api — the FRAME refuses to boot and
    /// installs no bridge, so the shell would sit on a blank webview until its
    /// 60s boot timeout. Failing at construction is far better.
    func testMalformedAppIdsAreRejected() {
        let bad = ["", "a", "-leading", ".dot", "has space", "has/slash", String(repeating: "a", count: 129), "native:", "emoji😀"]
        for appId in bad {
            let config = SnapneditCanvasConfiguration(credential: .publishableKey("pk", appId: appId))
            XCTAssertThrowsError(try config.frameURL(), "`\(appId)` should be rejected") { error in
                XCTAssertEqual((error as? SnapneditError)?.code, .invalidInput)
            }
        }
    }

    func testValidAppIdShapes() {
        for appId in ["ab", "e2e.app", "com.acme.photos", "my_app-1", "1app", String(repeating: "a", count: 128)] {
            XCTAssertNotNil(SnapneditProtocol.normalizeNativeOrigin(appId), "`\(appId)` should be accepted")
        }
    }

    func testDefaultTimeoutsMatchTheReferenceLoader() {
        let timeouts = SnapneditTimeouts.default
        XCTAssertEqual(timeouts.call, 30)
        XCTAssertEqual(timeouts.longRunningCall, 180)
        XCTAssertEqual(timeouts.ready, 60)
        XCTAssertEqual(timeouts.deadline(for: .export), 180)
        XCTAssertEqual(timeouts.deadline(for: .getState), 30)
    }

    // MARK: - data: URLs

    func testDataURLRoundTrip() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00])
        let url = SnapneditDataURL.encode(bytes, mime: "image/png")
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))
        let decoded = try XCTUnwrap(SnapneditDataURL.decode(url))
        XCTAssertEqual(decoded.data, bytes)
        XCTAssertEqual(decoded.mime, "image/png")
    }

    func testDataURLDecodesPercentEncoding() throws {
        let decoded = try XCTUnwrap(SnapneditDataURL.decode("data:text/plain,hello%20world"))
        XCTAssertEqual(String(data: decoded.data, encoding: .utf8), "hello world")
        XCTAssertEqual(decoded.mime, "text/plain")
    }

    func testDataURLRejectsGarbage() {
        XCTAssertNil(SnapneditDataURL.decode("https://example.com/a.png"))
        XCTAssertNil(SnapneditDataURL.decode("data:image/png;base64"))
    }

    func testEncodedBlobReadsTheFrameReplacement() throws {
        let bytes = Data([1, 2, 3])
        let blob = try XCTUnwrap(EncodedBlob(.object([
            "dataUrl": .string(SnapneditDataURL.encode(bytes, mime: "image/webp")),
            "mime": "image/webp",
            "bytes": 3,
        ])))
        XCTAssertEqual(blob.data, bytes)
        XCTAssertEqual(blob.mime, "image/webp")
        XCTAssertEqual(blob.declaredBytes, 3)
        XCTAssertNil(EncodedBlob(.object([:])))
        XCTAssertNil(EncodedBlob(nil))
    }

    func testRecommendedLimitMatchesProtocolJSON() {
        XCTAssertEqual(SnapneditLimits.recommendedMaxDataURLBytes, 4_194_304)
    }

    // MARK: - JSONValue

    func testJSONValueBridgesUntypedDictionaries() throws {
        let value = try XCTUnwrap(JSONValue(any: ["n": 1, "d": 1.5, "b": true, "s": "x", "a": [1, 2], "null": NSNull()] as [String: Any]))
        XCTAssertEqual(value["n"]?.intValue, 1)
        XCTAssertEqual(value["d"]?.doubleValue, 1.5)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["s"]?.stringValue, "x")
        XCTAssertEqual(value["a"]?.arrayValue?.count, 2)
        XCTAssertTrue(value["null"]!.isNull)
    }

    /// `NSNumber` erases `Bool`, and a `1` that arrives as `true` on the wire
    /// would be a genuinely confusing bug.
    func testJSONValueKeepsBoolsAndNumbersApart() throws {
        XCTAssertEqual(JSONValue(any: true), .bool(true))
        XCTAssertEqual(JSONValue(any: 1), .number(1))
        XCTAssertEqual(JSONValue(any: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(any: NSNumber(value: 1)), .number(1))
    }

    func testJSONValueRefusesUnencodableValues() {
        XCTAssertNil(JSONValue(any: Date()))
        XCTAssertNil(JSONValue(any: ["k": Date()] as [String: Any]))
    }
}
