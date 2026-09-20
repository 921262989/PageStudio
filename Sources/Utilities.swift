import Foundation
import UIKit
import ImageIO

// MARK: - 绘制几何

/// 笔迹的「逻辑坐标系」。
/// ⚠️ 页高固定 1000 点，与屏幕尺寸完全无关。
/// 这样转屏、切单页/双页，笔迹坐标都不会漂移。
enum DrawingGeometry {
    static let logicalPageHeight: CGFloat = 1000

    static func logicalPageWidth(ratio: Double) -> CGFloat {
        let r = max(ratio, 0.4)
        return logicalPageHeight / CGFloat(r)
    }

    static func spreadSize(ratio: Double) -> CGSize {
        CGSize(width: logicalPageWidth(ratio: ratio) * 2,
               height: logicalPageHeight)
    }
}

// MARK: - 文件目录

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

    static var drawingsDirectory: URL {
        ensure(documents.appendingPathComponent("Drawings", isDirectory: true))
    }

    static var coversDirectory: URL {
        ensure(documents.appendingPathComponent("Covers", isDirectory: true))
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

    // MARK: 封面

    static func coverURL(named name: String) -> URL {
        coversDirectory.appendingPathComponent(name)
    }

    static func saveCoverData(_ data: Data, preferredExtension ext: String) throws -> String {
        let name = UUID().uuidString + "." + ext
        try data.write(to: coverURL(named: name), options: .atomic)
        return name
    }

    static func deleteCover(named name: String) {
        try? FileManager.default.removeItem(at: coverURL(named: name))
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

enum ImageLoader {

    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 32
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
