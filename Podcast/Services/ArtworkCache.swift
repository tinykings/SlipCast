import CryptoKit
import Foundation
import ImageIO
import UIKit

/// On-device artwork cache. Podcast art is usually 1–3 MB at 3000px, which is too big for
/// `URLCache` to keep, so `AsyncImage` re-downloaded every poster on each launch.
/// Images are downsampled once to `storedPixelSize`, written to Caches/Artwork, and decoded
/// per display size into a memory cache.
nonisolated final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private static let storedPixelSize = 1024

    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    /// Synchronous memory-only lookup so already-seen art renders on the first frame.
    func cachedImage(for url: URL, pixelSize: Int) -> UIImage? {
        memory.object(forKey: memoryKey(url, pixelSize))
    }

    func image(for url: URL, pixelSize: Int) async -> UIImage? {
        let key = memoryKey(url, pixelSize)
        if let image = memory.object(forKey: key) { return image }
        guard let data = await storedData(for: url),
              let image = Self.downsample(data, maxPixelSize: pixelSize)
        else { return nil }
        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Disk

    private func storedData(for url: URL) async -> Data? {
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file) { return data }

        let key = url.absoluteString
        let task: Task<Data?, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let task = Task.detached(priority: .utility) { () -> Data? in
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = Self.downsample(data, maxPixelSize: Self.storedPixelSize),
                      let stored = image.jpegData(compressionQuality: 0.85)
                else { return nil }
                try? stored.write(to: file, options: .atomic)
                return stored
            }
            inFlight[key] = task
            return task
        }
        let data = await task.value
        lock.withLock { inFlight[key] = nil }
        return data
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }

    private func memoryKey(_ url: URL, _ pixelSize: Int) -> NSString {
        "\(pixelSize)|\(url.absoluteString)" as NSString
    }

    // MARK: - Decoding

    private static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }
}
