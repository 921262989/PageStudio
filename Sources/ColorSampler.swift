import SwiftUI
import UIKit
import PencilKit

/// 把「纸张 + 底图 + 笔迹」合成成一张位图，再从指定位置取像素颜色。
///
/// ⚠️ 为什么不能直接截屏：画布本身是透明的，只有笔迹。
///    要吸取照片上的颜色，必须把底图也一起合成出来。
enum ColorSampler {

    /// 合成整个跨页（像素图）。
    /// - Parameter displaySize: 这个跨页在屏幕上占的**点**尺寸，用来还原图片的填充与位移。
    static func renderSpread(book: Book,
                             spread: Spread,
                             displaySize: CGSize,
                             drawing: PKDrawing,
                             pixelScale: CGFloat = 1) -> UIImage? {
        guard displaySize.width > 1, displaySize.height > 1 else { return nil }

        let pixelSize = CGSize(width: displaySize.width * pixelScale,
                               height: displaySize.height * pixelScale)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 1) 纸张
            let paper = UIColor(red: PaperStyle.fillRGB.r,
                                green: PaperStyle.fillRGB.g,
                                blue: PaperStyle.fillRGB.b,
                                alpha: 1)
            cg.setFillColor(paper.cgColor)
            cg.fill(CGRect(origin: .zero, size: pixelSize))

            // 2) 底图
            if let idx = spread.fullSpreadPageIndex,
               book.pages.indices.contains(idx) {
                drawPage(book.pages[idx],
                         into: CGRect(origin: .zero, size: pixelSize),
                         baseDisplay: displaySize,
                         pixelScale: pixelScale,
                         cg: cg)
            } else {
                let sides = SpreadLayout.visualSides(of: spread,
                                                     binding: book.bindingDirection)
                let halfW = displaySize.width / 2

                if let li = sides.left, book.pages.indices.contains(li) {
                    let rect = CGRect(x: 0,
                                      y: 0,
                                      width: halfW * pixelScale,
                                      height: displaySize.height * pixelScale)
                    drawPage(book.pages[li],
                             into: rect,
                             baseDisplay: CGSize(width: halfW,
                                                 height: displaySize.height),
                             pixelScale: pixelScale,
                             cg: cg)
                }

                if let ri = sides.right, book.pages.indices.contains(ri) {
                    let rect = CGRect(x: halfW * pixelScale,
                                      y: 0,
                                      width: halfW * pixelScale,
                                      height: displaySize.height * pixelScale)
                    drawPage(book.pages[ri],
                             into: rect,
                             baseDisplay: CGSize(width: halfW,
                                                 height: displaySize.height),
                             pixelScale: pixelScale,
                             cg: cg)
                }
            }

            // 3) 笔迹
            if !drawing.strokes.isEmpty {
                let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
                let ink = drawing.image(from: CGRect(origin: .zero, size: logical),
                                        scale: 1)
                ink.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
    }

    /// 在归一化坐标（0~1）处取色
    static func sample(book: Book,
                       spread: Spread,
                       displaySize: CGSize,
                       drawing: PKDrawing,
                       atNormalized point: CGPoint) -> Color? {
        guard let image = renderSpread(book: book,
                                       spread: spread,
                                       displaySize: displaySize,
                                       drawing: drawing,
                                       pixelScale: 1),
              let cg = image.cgImage else { return nil }

        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }

        let x = Int((point.x * CGFloat(w)).rounded())
        let y = Int((point.y * CGFloat(h)).rounded())
        guard x >= 0, x < w, y >= 0, y < h else { return nil }

        // 把一个像素重绘到 1×1 的已知格式缓冲里，避开色彩空间与字节序的坑
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel,
                                  width: 1,
                                  height: 1,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.draw(cg, in: CGRect(x: -CGFloat(x),
                                y: -CGFloat(h - 1 - y),
                                width: CGFloat(w),
                                height: CGFloat(h)))

        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    // MARK: - 内部

    private static func drawPage(_ page: Page,
                                 into rect: CGRect,
                                 baseDisplay: CGSize,
                                 pixelScale: CGFloat,
                                 cg: CGContext) {
        guard let name = page.imageFileName,
              let img = ImageLoader.image(named: name, maxPixel: 2400) else { return }

        let imgW = img.size.width
        let imgH = img.size.height
        guard imgW > 0, imgH > 0 else { return }

        // 复刻 SwiftUI 的 scaledToFill + scaleEffect + offset
        let baseScale = max(baseDisplay.width / imgW, baseDisplay.height / imgH)
        let s = baseScale * CGFloat(page.transform.scale)

        let dw = imgW * s * pixelScale
        let dh = imgH * s * pixelScale

        let cx = rect.midX + CGFloat(page.transform.offsetX) * pixelScale
        let cy = rect.midY + CGFloat(page.transform.offsetY) * pixelScale

        cg.saveGState()
        cg.clip(to: rect)
        img.draw(in: CGRect(x: cx - dw / 2,
                            y: cy - dh / 2,
                            width: dw,
                            height: dh))
        cg.restoreGState()
    }
}
