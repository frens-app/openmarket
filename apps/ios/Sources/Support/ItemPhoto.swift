import CoreGraphics
import Foundation
import UIKit

/// A photo of the thing being sold, sized for the wire.
///
/// The pixel size is carried alongside the bytes because the server records it
/// and never keeps the image: when an identification comes back wrong, "they
/// sent a 4-megapixel photo" and "they sent a thumbnail" are different
/// explanations, and afterwards the dimensions are the only way to tell them
/// apart.
struct ItemPhoto: Equatable {
    let jpeg: Data
    let pixelSize: CGSize

    var byteCount: Int { jpeg.count }
}

/// Turns whatever the picker handed over into something worth uploading.
enum ItemPhotoPreparer {
    /// The long edge, in pixels, after downscaling.
    ///
    /// A modern iPhone photo is around 4000px on the long edge, which is far
    /// more than identifying a dresser needs and enough to make the request
    /// slow on a phone signal. 1568 is the middle of the range: still enough
    /// resolution to read a model number off a label, and roughly a tenth of
    /// the pixels.
    ///
    /// This is also the number the request-size ceiling is derived from — the
    /// server caps each photo at 4 MiB, and a JPEG this size lands far below
    /// that even at high quality. Raising it means checking that ceiling and
    /// whatever proxy sits in front of the API, not just editing this line.
    static let maxDimension: CGFloat = 1568

    /// High enough that compression artefacts don't become the thing in the
    /// photo, low enough that a 1568px image is a few hundred kilobytes.
    static let compressionQuality: CGFloat = 0.8

    /// Downscales and JPEG-encodes, preserving aspect ratio.
    ///
    /// Returns nil only if encoding fails, which in practice means an image
    /// with no drawable representation. The caller treats that as "no photo"
    /// rather than as an error: the run works on the description alone, and
    /// refusing to price something because its photo would not encode is a
    /// worse outcome than pricing it without one.
    static func prepare(_ image: UIImage) -> ItemPhoto? {
        let scaled = downscaled(image)
        guard let data = scaled.jpegData(compressionQuality: compressionQuality) else { return nil }
        return ItemPhoto(jpeg: data, pixelSize: scaled.size * scaled.scale)
    }

    /// Fits the image inside `maxDimension` on its longest edge.
    ///
    /// Images already smaller are returned untouched rather than scaled up:
    /// enlarging invents pixels, which costs bytes and adds nothing a model can
    /// read.
    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixels = image.size * image.scale
        let longest = max(pixels.width, pixels.height)
        guard longest > maxDimension, longest > 0 else { return image }

        let ratio = maxDimension / longest
        let target = CGSize(width: (pixels.width * ratio).rounded(),
                            height: (pixels.height * ratio).rounded())

        // scale: 1 so the format's size is in pixels rather than points —
        // otherwise the renderer multiplies by the device's scale factor and a
        // "1568px" image comes out at 4704px on a 3x screen, which is the
        // opposite of what this function is for.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
