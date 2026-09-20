import SwiftUI
import PencilKit

// MARK: - 纸张

struct PaperView: View {
    let theme: ReaderTheme

    var body: some View {
        ZStack {
            theme.paperColor

            LinearGradient(
                colors: [theme.paperEdgeShadow,
                         Color.clear,
                         Color.clear,
                         theme.paperEdgeShadow],
                startPoint: .leading,
                endPoint: .trailing
            )
            .opacity(0.55)
        }
    }
}

// MARK: - 书脊细线

/// 书脊处的一条细线。不投影、不加宽 —— 只为提示装订位置。
struct SpineLineView: View {
    let theme: ReaderTheme

    var body: some View {
        Rectangle()
            .fill(theme.spineLineColor)
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

    init(name: String,
         maxPixel: CGFloat = 2048,
         @ViewBuilder content: @escaping (Image) -> Content) {
        self.name = name
        self.maxPixel = maxPixel
        self.content = content
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                Color.clear
            }
        }
        .task(id: name) { await load() }
    }

    private func load() async {
        if let cached = ImageLoader.cache.object(forKey: name as NSString) {
            image = cached
            return
        }
        let url = FileStorage.imageURL(named: name)
        let pixel = maxPixel
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageLoader.downsample(url: url, maxPixel: pixel)
        }.value

        if let decoded {
            ImageLoader.cache.setObject(decoded, forKey: name as NSString)
        }
        image = decoded
    }
}

// MARK: - 跨页笔迹的烘焙图

/// 把某一跨页的笔迹渲染成一张透明叠图。
///
/// ⚠️ 只在「这一页不处于编辑状态」时使用。
/// 编辑中的页如果同时显示烘焙图，会和画布上的实时笔迹重叠，
/// 表现为「颜色变深、笔画变粗、几秒后变样」。
struct SpreadDrawingImage: View {
    let book: Book
    let spreadIndex: Int
    let size: CGSize
    let revision: Int
    /// 渲染倍率。2 能明显减少缩放后的锯齿与视觉变粗。
    var renderScale: CGFloat = 2

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(book.id.uuidString)-\(spreadIndex)-\(revision)") {
            await load()
        }
    }

    private func load() async {
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

        image = rendered
    }
}
