import Foundation

#if canImport(UIKit)
import UIKit
/// `UIImage` on iOS, `NSImage` on macOS.
public typealias SnapneditPlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
/// `UIImage` on iOS, `NSImage` on macOS.
public typealias SnapneditPlatformImage = NSImage
#endif

/// PNG-encoding whatever the platform calls an image, so
/// ``SnapneditEditorHandle/loadImage(_:name:)`` can take one directly.
///
/// PNG rather than JPEG on purpose: the editor is a compositor, and handing it
/// a lossily re-encoded copy of a photo the user already has is a quality loss
/// with nothing to show for it. Pass ``SnapneditEditorHandle/loadImage(data:mime:name:)``
/// with the ORIGINAL file bytes when you have them — that is better still,
/// since it skips a decode/encode round trip entirely.
public enum SnapneditPlatformImageCodec {
    #if canImport(UIKit)
    public static func pngData(_ image: UIImage) throws -> Data {
        guard let data = image.pngData() else {
            throw SnapneditError(code: .invalidInput, message: "could not PNG-encode the UIImage")
        }
        return data
    }
    #elseif canImport(AppKit)
    public static func pngData(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:])
        else {
            throw SnapneditError(code: .invalidInput, message: "could not PNG-encode the NSImage")
        }
        return data
    }
    #endif
}
