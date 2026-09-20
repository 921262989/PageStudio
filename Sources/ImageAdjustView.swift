import SwiftUI

/// 调整一张图在纸张内的显示范围：双指缩放、单指拖动、重置。
///
/// ⚠️ 位移以「逻辑坐标」保存（页高固定 1000）。
/// 这样编辑器里拖多少，阅读器里就移动多少，任何屏幕尺寸都一致。
struct ImageAdjustView: View {
    let page: Page
    let book: Book
    let onSave: (PageTransform) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var transform: PageTransform
    @State private var dragStart: CGPoint?
    @State private var magnifyStart: Double?
    @State private var showGrid = true

    init(page: Page,
         book: Book,
         onSave: @escaping (PageTransform) -> Void) {
        self.page = page
        self.book = book
        self.onSave = onSave
        _transform = State(initialValue: page.transform)
    }

    /// 预览区域的宽 / 高
    private var previewAspect: Double {
        let r = max(book.pageAspectRatio, 0.4)
        return page.occupiesSpread ? (2.0 / r) : (1.0 / r)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let size = fittedSize(in: geo.size)
                    ZStack {
                        Color.black.opacity(0.05)

                        pageCanvas(size: size)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                bottomControls
            }
            .navigationTitle("调整图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        onSave(transform)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - 预览画布

    @ViewBuilder
    private func pageCanvas(size: CGSize) -> some View {
        let k = size.height / DrawingGeometry.logicalPageHeight

        ZStack {
            PaperView()

            if let name = page.imageFileName {
                StoredImage(name: name, maxPixel: 2400) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(transform.scale)
                        .offset(x: transform.offsetX * k,
                                y: transform.offsetY * k)
                }
            }

            if showGrid {
                gridOverlay
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(
            Rectangle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
        .contentShape(Rectangle())
        .gesture(dragGesture(k: k))
        .simultaneousGesture(magnifyGesture)
    }

    private var gridOverlay: some View {
        GeometryReader { g in
            Path { path in
                let w = g.size.width
                let h = g.size.height

                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))

                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.black.opacity(0.12),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }
        .allowsHitTesting(false)
    }

    // MARK: - 手势

    private func dragGesture(k: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = CGPoint(x: transform.offsetX,
                                        y: transform.offsetY)
                }
                guard let start = dragStart, k > 0 else { return }
                transform.offsetX = Double(start.x + value.translation.width / k)
                transform.offsetY = Double(start.y + value.translation.height / k)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnifyStart == nil {
                    magnifyStart = transform.scale
                }
                guard let start = magnifyStart else { return }
                transform.scale = min(max(start * Double(value), 0.25), 6.0)
            }
            .onEnded { _ in
                magnifyStart = nil
            }
    }

    // MARK: - 底部控制

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        transform = .identity
                    }
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }

                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        transform.scale = min(transform.scale * 1.15, 6.0)
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }

                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        transform.scale = max(transform.scale * 0.87, 0.25)
                    }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }

                Button {
                    showGrid.toggle()
                } label: {
                    Image(systemName: showGrid ? "grid" : "grid.circle")
                }

                Spacer()

                Text(String(format: "%.0f%%", transform.scale * 100))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20)

            Text("双指缩放 · 单指拖动 · 拖动范围就是最终裁切范围")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
    }

    // MARK: - 尺寸

    private func fittedSize(in container: CGSize) -> CGSize {
        let maxW = max(container.width - 32, 60)
        let maxH = max(container.height - 32, 60)

        var w = maxW
        var h = w / previewAspect
        if h > maxH {
            h = maxH
            w = h * previewAspect
        }
        return CGSize(width: w, height: h)
    }
}
