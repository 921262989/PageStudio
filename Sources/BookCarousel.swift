import SwiftUI

/// 居中的书架：中间一本最大，两侧依次缩小并淡出。
/// 左右滑动切换，点中间的打开，长按弹出菜单。
struct BookCarousel: View {
    let books: [Book]
    @Binding var index: Int

    let onOpen: (Book) -> Void
    let onCover: (Book) -> Void
    let onRename: (Book) -> Void
    let onDelete: (Book) -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let itemWidth = min(width * 0.44, 360)
            let itemHeight = itemWidth * 1.38
            let step = itemWidth * 1.22

            ZStack {
                ForEach(Array(books.enumerated()), id: \.element.id) { idx, book in
                    let x = CGFloat(idx - index) * step + dragOffset

                    if abs(x) < step * 5 {
                        cover(book: book,
                              idx: idx,
                              itemWidth: itemWidth,
                              itemHeight: itemHeight)
                            .scaleEffect(scale(for: abs(x) / step))
                            .opacity(opacity(for: abs(x) / step))
                            .offset(x: x)
                            .zIndex(1000 - Double(abs(x)))
                    }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        dragOffset = value.translation.width
                    }
                    .onEnded { value in
                        guard !books.isEmpty else { return }
                        let predicted = value.predictedEndTranslation.width
                        let moved = -predicted / step
                        let target = index + Int(moved.rounded())
                        let clamped = min(max(target, 0), books.count - 1)

                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                            index = clamped
                            dragOffset = 0
                        }
                    }
            )
        }
    }

    @ViewBuilder
    private func cover(book: Book,
                       idx: Int,
                       itemWidth: CGFloat,
                       itemHeight: CGFloat) -> some View {
        NotebookCoverView(book: book, width: itemWidth)
            .frame(width: itemWidth, height: itemHeight)
            .onTapGesture {
                if idx == index {
                    onOpen(book)
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        index = idx
                    }
                }
            }
            .contextMenu {
                Button {
                    onCover(book)
                } label: {
                    Label("更换封面", systemImage: "paintpalette")
                }
                Button {
                    onRename(book)
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete(book)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
    }

    private func scale(for distance: CGFloat) -> CGFloat {
        max(0.66, 1 - distance * 0.17)
    }

    private func opacity(for distance: CGFloat) -> Double {
        Double(max(0.18, 1 - distance * 0.45))
    }
}
