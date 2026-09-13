import Foundation

/// `data:` URL encoding and decoding — the ONE mechanical difference between
/// the native bridge and the web embed.
///
/// JSON has no binary type, so the frame replaces every `Blob` in an envelope
/// with `{ dataUrl, mime, bytes }` before serializing, and a shell hands images
/// in the same way. Both halves live here.
public enum SnapneditDataURL {
    /// Builds `data:<mime>;base64,<...>`.
    public static func encode(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Decodes a `data:` URL into its bytes and mime type.
    ///
    /// Percent-encoded (non-base64) `data:` URLs are decoded too: the frame
    /// never produces one, but a shell may well be handed one.
    public static func decode(_ url: String) -> (data: Data, mime: String)? {
        guard url.hasPrefix("data:") else { return nil }
        let body = url.dropFirst("data:".count)
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let meta = body[body.startIndex..<comma]
        let payload = String(body[body.index(after: comma)...])
        let parts = meta.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let isBase64 = parts.contains { $0.lowercased() == "base64" }
        let mime = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "text/plain"
        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else { return nil }
            return (data, mime)
        }
        guard let decoded = payload.removingPercentEncoding, let data = decoded.data(using: .utf8) else { return nil }
        return (data, mime)
    }
}

/// A `Blob` as it crosses the native bridge: `{ dataUrl, mime, bytes }`.
struct EncodedBlob {
    let data: Data
    let mime: String
    /// The byte count the frame declared. Diagnostics only — the decoded bytes
    /// are what we hand the caller.
    let declaredBytes: Int

    /// Reads the replacement object the frame substitutes for a `Blob`.
    init?(_ value: JSONValue?) {
        guard let value, let dataUrl = value["dataUrl"]?.stringValue else { return nil }
        guard let decoded = SnapneditDataURL.decode(dataUrl) else { return nil }
        data = decoded.data
        mime = value["mime"]?.stringValue ?? decoded.mime
        declaredBytes = value["bytes"]?.intValue ?? decoded.data.count
    }
}
