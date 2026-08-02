import Foundation
import ImageIO

/// One decodable raster image on either side of a Git diff.
struct ImageDiffVersion: Equatable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int

    init?(data: Data) {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.data = data
        pixelWidth = image.width
        pixelHeight = image.height
        frameCount = CGImageSourceGetCount(source)
    }

    var formattedDimensions: String {
        "\(pixelWidth) x \(pixelHeight) px"
    }

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

/// Old and new raster contents for a selected file. A side is nil only
/// when Git says that side does not exist (an added or deleted image).
struct ImageDiff: Equatable {
    let old: ImageDiffVersion?
    let new: ImageDiffVersion?

    init?(oldData: Data?, newData: Data?) {
        let old = oldData.flatMap(ImageDiffVersion.init)
        let new = newData.flatMap(ImageDiffVersion.init)
        // A present but undecodable side must not be mistaken for an
        // addition or deletion. Fall back to the ordinary binary message.
        guard (oldData == nil || old != nil),
              (newData == nil || new != nil),
              old != nil || new != nil
        else { return nil }
        self.old = old
        self.new = new
    }

    /// SVG remains a textual diff. The list is intentionally limited to
    /// raster formats ImageIO commonly decodes on supported macOS versions.
    static func supports(path: String) -> Bool {
        supportedExtensions.contains(
            (path as NSString).pathExtension.lowercased()
        )
    }

    private static let supportedExtensions: Set<String> = [
        "apng", "avif", "bmp", "gif", "heic", "heif", "ico",
        "j2k", "jfif", "jp2", "jpeg", "jpg", "png", "psd",
        "tif", "tiff", "webp",
    ]
}
