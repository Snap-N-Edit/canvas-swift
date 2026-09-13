import Foundation

/// Turning one JSON message into a JavaScript source string.
///
/// The shell's only way into the frame is
/// `window.SnapneditNativeBridge.receive(<literal>)`, evaluated as source. The
/// literal therefore has to survive being pasted into a JavaScript program —
/// a strictly stronger requirement than being valid JSON:
///
/// * `U+2028` / `U+2029` are legal inside a JSON string but were, until
///   ES2019, line terminators in JavaScript source. Anything older, or any
///   engine pre-parsing the string, breaks on them.
/// * `</script` inside the literal closes a surrounding `<script>` block if
///   the source is ever templated into HTML.
/// * Quotes, backslashes and the C0 control range must be escaped, as in JSON.
///
/// `JSONSerialization` / `JSONEncoder` handle neither of the first two, so the
/// literal is built here rather than by re-encoding the string as JSON.
public enum SnapneditJavaScript {
    /// Wraps `value` in a double-quoted JavaScript string literal that is safe
    /// in any source position, including inside HTML.
    public static func stringLiteral(_ value: String) -> String {
        var out = "\""
        out.reserveCapacity(value.utf8.count + 2)
        var previousWasLessThan = false
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            case "\u{2028}":
                out += "\\u2028"
            case "\u{2029}":
                out += "\\u2029"
            case "/":
                // Only the `/` that closes a tag needs neutralizing, and the
                // cheapest correct rule is: escape a `/` that follows a `<`.
                out += previousWasLessThan ? "\\/" : "/"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            previousWasLessThan = scalar == "<"
        }
        out += "\""
        return out
    }

    /// The complete expression the shell evaluates to hand the frame one
    /// message. Guarded so an evaluation that races the bridge's installation
    /// yields `false` instead of a `ReferenceError`.
    public static func receiveCall(json: String) -> String {
        let global = "window.\(SnapneditProtocol.bridgeGlobal)"
        return "(!!\(global) && \(global).receive(\(stringLiteral(json))))"
    }
}
