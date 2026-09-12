import Foundation
import ImageIO

/// A serial, non-main executor bounds decode work even when many tiles appear.
actor ChatAttachmentImageLoader {
    static let shared = ChatAttachmentImageLoader()
    static let thumbnailPixelLimit = 320
    static let previewPixelLimit = 2560

    func load(url: URL, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled, url.isFileURL else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false
            ] as CFDictionary), !Task.isCancelled else { return nil }
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, Self.previewPixelLimit)),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
            return Task.isCancelled ? nil : image
        }
    }
}
