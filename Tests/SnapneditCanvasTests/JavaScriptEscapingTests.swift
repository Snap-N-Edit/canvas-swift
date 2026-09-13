import Foundation
import XCTest
@testable import SnapneditCanvas

/// The literal the shell pastes into `evaluateJavaScript`.
///
/// This is the one place where "valid JSON" is not good enough: the string is
/// evaluated as JavaScript SOURCE, so it has to survive a parser, not just a
/// decoder.
final class JavaScriptEscapingTests: XCTestCase {
    private func literal(_ value: String) -> String { SnapneditJavaScript.stringLiteral(value) }

    func testPlainStringIsQuoted() {
        XCTAssertEqual(literal("hello"), "\"hello\"")
    }

    func testQuotesAndBackslashes() {
        XCTAssertEqual(literal("say \"hi\""), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(literal("C:\\path"), "\"C:\\\\path\"")
        // A backslash immediately before a quote must not escape our escape.
        XCTAssertEqual(literal("\\\""), "\"\\\\\\\"\"")
    }

    func testNewlinesAndControlCharacters() {
        XCTAssertEqual(literal("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(literal("a\rb"), "\"a\\rb\"")
        XCTAssertEqual(literal("a\tb"), "\"a\\tb\"")
        XCTAssertEqual(literal("a\u{0B}b"), "\"a\\u000bb\"")
        XCTAssertEqual(literal("a\u{00}b"), "\"a\\u0000b\"")
    }

    /// U+2028 and U+2029 are legal inside a JSON string but were JavaScript
    /// LINE TERMINATORS until ES2019 — a JSON encoder leaves them alone and
    /// the literal stops being one line of source.
    func testLineAndParagraphSeparators() {
        XCTAssertEqual(literal("a\u{2028}b"), "\"a\\u2028b\"")
        XCTAssertEqual(literal("a\u{2029}b"), "\"a\\u2029b\"")
        XCTAssertFalse(literal("a\u{2028}b").unicodeScalars.contains("\u{2028}"))
    }

    /// `</script` inside the literal closes a surrounding `<script>` block if
    /// the source is ever templated into HTML.
    func testScriptCloseIsNeutralized() {
        XCTAssertEqual(literal("</script>"), "\"<\\/script>\"")
        XCTAssertFalse(literal("payload </script><img onerror=x>").contains("</script>"))
    }

    /// Only the `/` after a `<` is escaped — a url full of slashes must stay
    /// readable, and escaping every one would bloat a megabyte-long data: URL.
    func testOrdinarySlashesAreLeftAlone() {
        XCTAssertEqual(literal("https://a/b"), "\"https://a/b\"")
    }

    func testNonASCIIIsPassedThrough() {
        XCTAssertEqual(literal("café 😀"), "\"café 😀\"")
    }

    /// The end-to-end property: the literal, parsed as a JSON string (which is
    /// a subset of a JavaScript string literal for these inputs), must yield
    /// exactly what went in.
    func testLiteralRoundTrips() throws {
        let inputs = [
            "plain",
            "quote \" backslash \\ slash /",
            "line\nbreak\ttab",
            "u2028\u{2028}u2029\u{2029}",
            "</script><script>alert(1)</script>",
            "emoji 😀 accents éüñ",
            "\u{00}\u{01}\u{1F}",
            #"{"snapnedit":1,"type":"call"}"#,
        ]
        for input in inputs {
            let source = literal(input)
            // A JavaScript literal escapes `/` as `\/`, which JSON also
            // accepts, so JSONDecoder is a faithful parser for our output.
            let decoded = try JSONDecoder().decode(String.self, from: XCTUnwrap(source.data(using: .utf8)))
            XCTAssertEqual(decoded, input, "round trip failed for \(input.debugDescription)")
        }
    }

    /// A whole envelope, escaped and re-parsed — the real path.
    func testEnvelopeRoundTripsThroughTheLiteral() throws {
        let json = try SnapneditOutboundEnvelope
            .call(id: "1", method: .loadImage, args: [.string("data:image/png;base64,iVBORw0KGgo=</script>\u{2028}")])
            .json()
        let expression = SnapneditJavaScript.receiveCall(json: json)
        XCTAssertTrue(expression.hasPrefix("(!!window.SnapneditNativeBridge && window.SnapneditNativeBridge.receive("))
        XCTAssertTrue(expression.hasSuffix("))"))

        let start = try XCTUnwrap(expression.range(of: ".receive(")).upperBound
        let literalSource = String(expression[start..<expression.index(expression.endIndex, offsetBy: -2)])
        let recovered = try JSONDecoder().decode(String.self, from: XCTUnwrap(literalSource.data(using: .utf8)))
        XCTAssertEqual(recovered, json)
        let value = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(recovered.data(using: .utf8)))
        XCTAssertEqual(value["payload"]?["method"]?.stringValue, "loadImage")
    }

    /// The expression must be guarded: an evaluation that races the bridge's
    /// installation should be `false`, not a `ReferenceError` in the console.
    func testReceiveCallIsGuarded() {
        XCTAssertTrue(SnapneditJavaScript.receiveCall(json: "{}").contains("!!window.SnapneditNativeBridge &&"))
    }
}
