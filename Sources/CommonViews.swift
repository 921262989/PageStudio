import SwiftUI
import UIKit
import PencilKit

// MARK: - 笔迹位图共享缓存

/// 翻页时，同一个跨页会同时出现在「当前静止页」「翻页卡片正面」「翻页卡片背面」
/// 「对开页」等好几个视图里。如果每个视图各渲染一份 2828×2000 的位图，
/// 一次翻页就是上百 MB —— 表现为：卡顿、发烫、闪一下、甚至被系统杀掉。
///
/// 这里做全局共享 + 内存警告自动清理。
final class InkImageCache {
    static let shared = InkImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 48
        cache.totalCostLimit = 96 * 1024 * 1024

        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        let cost = Int(pixels * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

// MARK: - 纸张

struct PaperView: View {
    var theme: ReaderTheme? = nil

    var body: some View {
        ZStack {
            PaperStyle.fill

            LinearGradient(
                colors: [PaperStyle.edgeShadow,
                         Color.clear,
                         Color.clear,
                         PaperStyle.edgeShadow],
                startPoint: .leading,
                endPoint: .trailing
            )
            .opacity(0.55)
        }
    }
}

// MARK: - 书脊细线

struct SpineLineView: View {
    var theme: ReaderTheme? = nil

    var body: some View {
        Rectangle()
            .fill(PaperStyle.spineLine)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

// MARK: - 阅读区背景

struct ReaderBackground: View {
    let theme: ReaderTheme

    var body: some View {
        LinearGradient(colors: theme.backgroundColors,
                       startPoint: .top,
                       endPoint: .bottom)
            .ignoresSafeArea()
    }
}

// MARK: - 磁盘图片容器

struct StoredImage<Content: View>: View {
    let name: String
    let maxPixel: CGFloat
    private let content: (Image) -> Content

    @State private var image: UIImage? = nil
    @State private var loadedName: String = ""

    init(name: String,
         maxPixel: CGFloat = 2048,
         @ViewBuilder content: @escaping (Image) -> Content) {
        self.name = name
        self.maxPixel = maxPixel
        self.content = content
    }

    var body: some View {
        // 缓存命中时直接同步取到，避免第一帧空白造成「闪一下」
        let cached = ImageLoader.cache.object(forKey: name as NSString)
        let shown: UIImage? = (loadedName == name ? image : nil) ?? cached

        Group {
            if let shown {
                content(Image(uiImage: shown))
            } else {
                Color.clear
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        if let cached = ImageLoader.cache.object(forKey: name as NSString) {
            if loadedName != name {
                loadedName = name
                image = cached
            }
            return
        }

        let url = FileStorage.imageURL(named: name)
        let pixel = maxPixel
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageLoader.downsample(url: url, maxPixel: pixel)
        }.value

        guard !Task.isCancelled else { return }

        if let decoded {
            ImageLoader.cache.setObject(decoded, forKey: name as NSString)
        }
        loadedName = name
        image = decoded
    }
}

// MARK: - 把 PKDrawing 渲染成叠图

/// 通用版：直接给一个 `PKDrawing`，渲染成与 size 等大的透明叠图。
/// 图层渲染用它；单层笔迹也用得上。
struct InkImageView: View {
    let drawing: PKDrawing
    let size: CGSize
    /// 外部版本号。变了就重新渲染。
    let revision: Int

    /// 渲染倍率。
    /// nil（默认）= 按屏幕上实际要显示的尺寸自动算，这是推荐用法。
    /// 单独传值仍然是允许的（老代码兼容）。
    var renderScale: CGFloat? = nil
    var opacity: Double = 1.0

    @State private var image: UIImage?
    @State private var imageKey: String = ""

    var body: some View {
        let key = cacheKey

        // ⚠️ 这里是「翻页闪一下」的关键修复：
        //    先看内存里有没有现成的位图，有就【同步】取出来直接画。
        //    以前是「先画一帧空白，等异步渲染完再替换」，那一帧空白就是你看到的闪。
        let shown: UIImage? = (imageKey == key ? image : nil)
            ?? InkImageCache.shared.image(forKey: key)

        Group {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .opacity(opacity)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: key) {
            await render(key: key)
        }
    }

    /// 自动渲染倍率：按屏幕上实际要显示的尺寸算。
    /// 以前固定 2× → 2828×2000（22.6MB/层）。现在跟着显示尺寸走，
    /// 位图小 3~4 倍，渲染也快，闪的时间也就没了。
    private var effectiveScale: CGFloat {
        if let renderScale { return renderScale }
        guard size.height > 1 else { return 1 }
        let raw = size.height / DrawingGeometry.logicalPageHeight * 2
        return min(max(raw, 0.75), 2.5)
    }

    /// 缓存键。
    /// PKDrawing 是值类型（struct），不能用 ObjectIdentifier，
    /// 所以这里用「笔画数 + 总锚点数 + 包围盒 + 渲染尺寸」拼一个内容指纹。
    /// 同一个跨页在同一内容下翻来翻去，就能命中同一个位图。
    private var cacheKey: String {
        let logical = DrawingGeometry.spreadSize(ratio: 1.414)
        let scale = effectiveScale
        let b = drawing.bounds
        let strokeCount = drawing.strokes.count
        let anchorCount = drawing.strokes.reduce(0) { $0 + $1.path.count }

        let fx = Int(b.origin.x * 100)
        let fy = Int(b.origin.y * 100)
        let fw = Int(b.width * 100)
        let fh = Int(b.height * 100)

        return "ink-\(strokeCount)-\(anchorCount)-\(fx)-\(fy)-\(fw)-\(fh)"
            + "-\(Int(logical.width))x\(Int(logical.height))-\(Int(scale * 100))"
    }

    private func render(key: String) async {
        // 命中缓存：直接放上，不渲染
        if let cached = InkImageCache.shared.image(forKey: key) {
            if imageKey != key {
                imageKey = key
                image = cached
            }
            return
        }

        guard !drawing.strokes.isEmpty else {
            imageKey = key
            image = nil
            return
        }

        let logical = DrawingGeometry.spreadSize(ratio: 1.414)
        let target = CGRect(origin: .zero, size: logical)
        let scale = effectiveScale
        let d = drawing

        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            d.image(from: target, scale: scale)
        }.value

        guard !Task.isCancelled else { return }

        if let rendered {
            InkImageCache.shared.store(rendered, forKey: key)
        }

        imageKey = key
        image = rendered
    }
}

// MARK: - 跨页笔迹的烘焙图（单层 · 旧用法）

/// ⚠️ 只在「这一页不处于编辑状态」时使用。
/// 编辑中的页如果同时显示烘焙图，会和画布上的实时笔迹重叠，
/// 表现为「颜色变深、笔画变粗、几秒后变样」。
struct SpreadDrawingImage: View {
    let book: Book
    let spreadIndex: Int
    let size: CGSize
    let revision: Int
    var renderScale: CGFloat = 2

    @State private var image: UIImage?
    @State private var imageKey: String = ""

    var body: some View {
        let key = cacheKey
        let shown: UIImage? = (imageKey == key ? image : nil)
            ?? InkImageCache.shared.image(forKey: key)

        Group {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: key) {
            await load(key: key)
        }
    }

    private var cacheKey: String {
        "spread-\(book.id.uuidString)-\(spreadIndex)-\(Int(size.width))x\(Int(size.height))-\(Int(renderScale * 100))"
    }

    private func load(key: String) async {
        if let cached = InkImageCache.shared.image(forKey: key) {
            if imageKey != key {
                imageKey = key
                image = cached
            }
            return
        }

        let bookId = book.id
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
        let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
        let scale = renderScale

        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let drawing = try? PKDrawing(data: data),
                  !drawing.strokes.isEmpty else { return nil }
            return drawing.image(from: CGRect(origin: .zero, size: logical),
                                 scale: scale)
        }.value

        guard !Task.isCancelled else { return }

        if let rendered {
            InkImageCache.shared.store(rendered, forKey: key)
        }

        imageKey = key
        image = rendered
    }
}
