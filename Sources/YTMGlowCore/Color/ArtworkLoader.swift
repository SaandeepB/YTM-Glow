import CoreGraphics
import Foundation
import ImageIO

/// Album art may only come from the image hosts YouTube Music itself uses.
public enum ArtworkPolicy {
    public static let allowedHostSuffixes = ["googleusercontent.com", "ytimg.com", "ggpht.com"]
    public static let maxBytes = 4 * 1024 * 1024

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The smallest allowed image at least `preferredEdge` px, else the largest.
    public static func pick(_ images: [ArtworkImage], preferredEdge: Int) -> URL? {
        let candidates: [(url: URL, edge: Int)] = images.compactMap { image in
            guard let url = URL(string: image.src), isAllowed(url) else { return nil }
            return (url, image.largestEdge ?? 0)
        }
        guard !candidates.isEmpty else { return nil }
        if let fit = candidates.filter({ $0.edge >= preferredEdge }).min(by: { $0.edge < $1.edge }) {
            return fit.url
        }
        return candidates.max { $0.edge < $1.edge }?.url
    }
}

/// Downloads album art (allowed hosts only, redirects included) and caches
/// decoded images and palettes in memory.
public final class ArtworkLoader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    private let cache = NSCache<NSURL, CachedArtwork>()

    final class CachedArtwork {
        let image: CGImage
        let palette: Palette?
        init(image: CGImage, palette: Palette?) {
            self.image = image
            self.palette = palette
        }
    }

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": LRCLibClient.defaultUserAgent]
        session = URLSession(configuration: configuration)
        cache.countLimit = 24
        super.init()
    }

    public func load(_ url: URL) async -> (image: CGImage, palette: Palette?)? {
        guard ArtworkPolicy.isAllowed(url) else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return (cached.image, cached.palette) }

        guard let (data, response) = try? await session.data(from: url, delegate: self),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= ArtworkPolicy.maxBytes,
              let image = Self.decode(data) else { return nil }
        let palette = PaletteExtractor.extract(from: image)
        cache.setObject(CachedArtwork(image: image, palette: palette), forKey: url as NSURL)
        return (image, palette)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, ArtworkPolicy.isAllowed(url) else { return nil }
        return request
    }
}
