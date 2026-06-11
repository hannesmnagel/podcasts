import ImageIO
import SwiftUI
import UIKit

/// Decodes only a thumbnail at the required pixel size via ImageIO.
/// Widget extensions have a tight memory cap (~30 MB) and get killed silently
/// if exceeded — this keeps each image at the actual display size instead of
/// loading the full-resolution original.
func loadThumbnail(url: URL, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
    let effectiveScale = scale > 0 ? scale : 2
    let maxPixels = min(Int(pointSize * effectiveScale), 300)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: false,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cgImage)
}
