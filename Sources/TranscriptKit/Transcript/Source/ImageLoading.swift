import Foundation
import ImageIO

/// A decoded image and its pixel size.
public struct LoadedImage: Sendable {
    public var image: CGImage
    public var pixelSize: CGSize

    public init(image: CGImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
    }
}

/// Loads images shown in the transcript (Markdown images, attachments). Runs off the main actor.
public protocol TranscriptImageLoading: Sendable {
    func load(_ source: String) async -> LoadedImage?
}

/// Loads `file:`, `data:` and `https:` images (plain `http:` is not loaded), decoding a bounded thumbnail off the
/// main actor. Network loads are limited in size and time.
public struct DefaultImageLoader: TranscriptImageLoading {
    public static let maxBytes = 25 << 20
    public static let maxPixelSize = 2_400

    public init() {}

    @concurrent
    public func load(_ source: String) async -> LoadedImage? {
        guard let data = await Self.data(for: source), !Task.isCancelled else { return nil }
        return Self.decode(data)
    }

    static func data(for source: String) async -> Data? {
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64") else { return nil }
            return Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
        }
        guard let url = URL(string: source) ?? URL(fileURLWithPath: source) as URL? else { return nil }
        if url.isFileURL || source.hasPrefix("/") {
            let fileURL = url.isFileURL ? url : URL(fileURLWithPath: source)
            guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes else { return nil }
            return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
        guard url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("BelloCode", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, data.count <= maxBytes
        else { return nil }
        return data
    }

    static func decode(_ data: Data) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let size = width > 0 && height > 0 ? CGSize(width: width, height: height) : CGSize(width: image.width, height: image.height)
        return LoadedImage(image: image, pixelSize: size)
    }
}
