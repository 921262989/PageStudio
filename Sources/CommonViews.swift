import SwiftUI
import PencilKit

// MARK: - 纸张 / 装订线 / 背景

struct PaperView: View {
    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.985, blue: 0.97)
            LinearGradient(
                colors: [Color.black.opacity(0.05),
                         Color.clear,
                         Color.clear,
                         Color.black.opacity(0.05)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct SpineView: View {
    var body: some View {
        LinearGradient(
            colors: [.clear,
                     .black.opacity(0.10),
                     .black.opacity(0.22),
                     .black.opacity(0.10),
                     .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 48)
        .allowsHitTesting(false)
    }
}

struct ReaderBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
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

// MARK: - 跨页笔迹渲染

/// 把某一跨页的笔迹渲染成一张图，叠在底图之上。
/// 浏览模式下也能看到自己的笔迹（旧版本这里是缺的）。
struct SpreadDrawingImage: View {
    let book: Book
    let spreadIndex: Int
    let size: CGSize
    let revision: Int

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
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

        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url),
                  let drawing = try? PKDrawing(data: data),
                  !drawing.strokes.isEmpty else { return nil }
            return drawing.image(from: CGRect(origin: .zero, size: logical), scale: 1)
        }.value

        image = rendered
    }
}
