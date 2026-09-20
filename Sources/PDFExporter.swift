import SwiftUI
import UIKit
import PencilKit

@MainActor
enum PDFExporter {

    /// 把整本画册渲染成 PDF，写到临时目录并返回 URL
    static func export(book: Book,
                       layerStore: LayerStore,
                       theme: ReaderTheme) -> URL? {
        let spreads = SpreadLayout.spreads(for: book)
        guard !spreads.isEmpty else { return nil }

        // 预热：把用到的图片同步读进缓存，
        // 否则 ImageRenderer 渲染时图片还没加载，会导出成空白
        for page in book.pages {
            if let name = page.imageFileName {
                _ = ImageLoader.image(named: name, maxPixel: 2048)
            }
        }

        let ratio = max(book.pageAspectRatio, 0.4)
        let pageH: CGFloat = 1200
        let pageW = pageH / ratio
        let scale: CGFloat = 2
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)

        let safeName = book.title
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (safeName.isEmpty ? "画册" : safeName) + ".pdf"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: book.title]

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH),
            format: format
        )

        let data = renderer.pdfData { ctx in
            for spread in spreads {
                ctx.beginPage()
                let target = CGRect(x: 0, y: 0, width: pageW, height: pageH)
                let image = renderSpread(book: book,
                                         spread: spread,
                                         size: CGSize(width: pageW, height: pageH),
                                         logical: logical,
                                         scale: scale,
                                         layerStore: layerStore,
                                         theme: theme)
                image.draw(in: target)
            }
        }

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func renderSpread(book: Book,
                                     spread: Spread,
                                     size: CGSize,
                                     logical: CGSize,
                                     scale: CGFloat,
                                     layerStore: LayerStore,
                                     theme: ReaderTheme) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            // ① 底图：纸张 + 页面图片（含内页样式）
            let content = SpreadCanvasView(book: book,
                                           spread: spread,
                                           pageWidth: size.width / 2,
                                           pageHeight: size.height,
                                           drawingRevision: 0,
                                           showDrawing: false,
                                           theme: theme)
                .frame(width: size.width, height: size.height)

            let imageRenderer = ImageRenderer(content: content)
            imageRenderer.scale = scale
            imageRenderer.isOpaque = true

            if let base = imageRenderer.uiImage {
                base.draw(in: CGRect(origin: .zero, size: size))
            }

            // ② 图层笔迹
            let layers = layerStore.layers(bookId: book.id, spreadIndex: spread.index)

            for meta in layers where meta.isVisible {
                let drawing = layerStore.drawing(bookId: book.id,
                                                 spreadIndex: spread.index,
                                                 layerID: meta.id)
                guard !drawing.strokes.isEmpty else { continue }
                guard let ink = drawing.image(from: CGRect(origin: .zero, size: logical),
                                              scale: scale) else { continue }

                ctx.cgContext.saveGState()
                ctx.cgContext.setAlpha(CGFloat(min(max(meta.opacity, 0), 1)))
                ink.draw(in: CGRect(origin: .zero, size: size))
                ctx.cgContext.restoreGState()
            }
        }
    }
}
