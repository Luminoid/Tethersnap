import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Grid thumbnails for file-backed captures, as JPEG bytes so the app's
/// decode path is the same as for device thumbnails. Synchronous: the video
/// leg blocks on a semaphore, so call it from the service's own executor
/// queue, never from the main thread or the cooperative pool.
enum VolumeThumbnailer {
    /// Matches the app's grid request so a file thumbnail is decoded once at
    /// the size the cell draws, never upscaled from a smaller JPEG.
    static let maxPixelSize = 480
    static let videoTimeout: TimeInterval = 10
    /// Where a frame is taken from: the first frame of a console clip is
    /// often black, and the generator's default tolerance picks the nearest
    /// keyframe anyway.
    private static let videoFrameTime = CMTime(seconds: 1, preferredTimescale: 600)

    /// Embedded EXIF thumbnail when present, else a downsampled decode
    /// (ImageIO handles camera RAW); nil for anything it cannot read.
    static func jpegThumbnail(forImageAt url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            TethersnapLog.debug(.volume, "no image thumbnail", private: url.path)
            return nil
        }
        return jpegData(image)
    }

    /// One frame near the start of the clip. The asset and generator are
    /// built inside the task (neither is Sendable); only JPEG bytes cross back.
    static func jpegThumbnail(forVideoAt url: URL, timeout: TimeInterval = videoTimeout) -> Data? {
        let result = Mutex<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            defer { done.signal() }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            do {
                let (image, _) = try await generator.image(at: videoFrameTime)
                let jpeg = jpegData(image)
                result.withLock { $0 = jpeg }
            } catch {
                TethersnapLog.debug(.volume, "no video thumbnail", private: url.path, error: error)
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            TethersnapLog.warning(.volume, "video thumbnail timed out", private: url.path)
            return nil
        }
        return result.withLock { $0 }
    }

    /// Encode through an opaque redraw: ImageIO thumbnails are premultiplied
    /// RGBA even from opaque sources, and the JPEG encoder warns
    /// (`AlphaPremulLast`) and wastes a channel unless the alpha is dropped first.
    static func jpegData(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let opaque = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, opaque, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
