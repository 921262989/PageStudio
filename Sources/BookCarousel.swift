import SwiftUI

/// 居中排成一排的书架。左右滑动选择，中间那本最大。
struct BookCarousel: View {
    let books: [Book]
    @Binding var index: Int

    let onOpen: (Book) -> Void
    let onCover: (Book) -> Void
    let onRename: (Book) -> Void
    let onDelete: (Book) -> Void

    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let itemWidth = min(width * 0.46, 380)
            let step = itemWidth * 1.20

            ZStack {
                ForEach(Array(books.enumerated()), id: \.element.id) { idx, book in
                    let x = CGFloat(idx - index) * step + drag

                    if abs(x) < step * 5 || drag != 0 {
                        cover(book: book, isCentered: idx == index)
                            .frame(width: itemWidth, height: itemWidth * 1.38)
                            .scaleEffect(scale(for: abs(x) / step))
                            .opacity(opacity(for: abs(x) / step))
                            .offset(x: x)
                            .zIndex(Double(1000 - abs(x)))
                            .onTapGesture {
                                if idx == index {
                                    onOpen(book)
                                } else {
                                    withAnimation(.spring(response: 0.38,
                                                          dampingFraction: 0.82)) {
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
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        guard !books.isEmpty else { return }
                        let predicted = value.predictedEndTranslation.width
                        let moved = -predicted / step
                        let target = index + Int(moved.rounded())
                        let clamped = min(max(target, 0), books.count - 1)
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                            index = clamped
                        }
                    }
            )
        }
    }

    private func scale(for distance: CGFloat) -> CGFloat {
        max(0.66, 1 - distance * 0.17)
    }

    private func opacity(for distance: CGFloat) -> Double {
        Double(max(0.20, 1 - distance * 0.42))
    }

    @ViewBuilder
    private func cover(book: Book, isCentered: Bool) -> some View {
        ZStack {
            NotebookCoverView(book: book, width: 1)
                .scaleEffect(1, anchor: .center)

            // NotebookCoverView 需要明确宽度，这里用 GeometryReader 兜一层
            GeometryReader { g in
                NotebookCoverView(book: book, width: g.size.width)
            }
        }
        .overlay(alignment: .bottom) {
            if isCentered {
                VStack(spacing: 3) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(book.pages.count) 页")
                        if !book.outline.isEmpty {
                            Text("·")
                            Text("\(book.outline.count) 条目")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .offset(y: 40)
            }
        }
    }
}
