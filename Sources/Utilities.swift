import Foundation
import UIKit
import ImageIO

// MARK: - 文件目录

/// 统一管理沙盒里的文件目录。所有数据都在本机，全程无网络请求。
enum FileStorage {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var libraryFile: URL {
        documents.appendingPathComponent("library.json")
    }

    static var imagesDirectory: URL {
        ensure(documents.appendingPathComponent("Images", isDirectory: true))
    }

    static var thumbnailsDirectory: URL {
        ensure(documents.appendingPathComponent("Thumbnails", isDirectory: true))
    }

    /// 笔迹目录：Drawings/<bookId>/<spreadIndex>.drawing
    static var drawingsDirectory: URL {
        ensure(documents.appendingPathComponent("Drawings", isDirectory: true))
    }

    /// 导出临时目录
    static var exportDirectory: URL {
        ensure(documents.appendingPathComponent("Exports", isDirectory: true))
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url,
                                                     withIntermediateDirectories: true)
        }
        return url
    }

    // MARK: 图片

    static func imageURL(named name: String) -> URL {
        imagesDirectory.appendingPathComponent(name)
    }

    static func saveImageData(_ data: Data, preferredExtension ext: String) throws -> String {
        let name = UUID().uuidString + "." + ext
        try data.write(to: imageURL(named: name), options: .atomic)
        return name
    }

    static func deleteImage(named name: String) {
        try? FileManager.default.removeItem(at: imageURL(named: name))
    }

    // MARK: 笔迹

    static func bookDrawingsDirectory(bookId: UUID) -> URL {
        ensure(drawingsDirectory.appendingPathComponent(bookId.uuidString,
                                                        isDirectory: true))
    }

    static func drawingURL(bookId: UUID, spreadIndex: Int) -> URL {
        bookDrawingsDirectory(bookId: bookId)
            .appendingPathComponent("\(spreadIndex).drawing")
    }

    static func deleteDrawings(bookId: UUID) {
        let dir = drawingsDirectory.appendingPathComponent(bookId.uuidString,
                                                           isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - 图片加载

/// 图片解码 + 内存缓存。用「降采样」避免大图撑爆内存。
enum ImageLoader {

    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 24
        return c
    }()

    static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                options as CFDictionary)
        else { return nil }

        return UIImage(cgImage: cgImage)
    }

    static func image(named name: String, maxPixel: CGFloat = 2048) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let url = FileStorage.imageURL(named: name)
        guard let image = downsample(url: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

// MARK: - 图片格式识别

enum ImageFileType {

    static func fileExtension(for data: Data) -> String {
        guard data.count >= 12 else { return "jpg" }
        let bytes = [UInt8](data.prefix(12))

        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50,
           bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        if bytes[0] == 0x52, bytes[1] == 0x49,
           bytes[2] == 0x46, bytes[3] == 0x46 { return "webp" }
        if bytes[4] == 0x66, bytes[5] == 0x74,
           bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("avi") { return "avif" }
            return "heic"
        }
        return "jpg"
    }
}
