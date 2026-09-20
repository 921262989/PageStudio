import SwiftUI
import PencilKit

// MARK: - 单页底图

struct PageContentView: View {
    let page: Page
    let size: CGSize
    let theme: ReaderTheme

    var body: some View {
        ZStack {
            PaperView(theme: theme)

            if let name = page.imageFileName {
                StoredImage(name: name) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(page.transform.scale)
                        .offset(x: page.transform.offsetX,
                                y: page.transform.offsetY)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - 跨页渲染（底图 + 笔迹）

/// 整个跨页作为一块画布渲染。单页模式只是裁它的一半 —— 笔迹坐标天然一致。
struct SpreadCanvasView: View {
    let book: Book
    let spread: Spread
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let drawingRevision: Int
    let showDrawing: Bool
    let theme: ReaderTheme

    private var spreadSize: CGSize {
        CGSize(width: pageWidth * 2, height: pageHeight)
    }

    var body: some View {
        ZStack {
            if let idx = spread.fullSpreadPageIndex, book.pages.indices.contains(idx) {
                // 「两页一张」：整张图铺满整个跨页
                PageContentView(page: book.pages[idx],
                                size: spreadSize,
                                theme: theme)
            } else {
                let sides = SpreadLayout.visualSides(of: spread,
                                                     binding: book.bindingDirection)
                HStack(spacing: 0) {
                    slot(pageIndex: sides.left)
                    slot(pageIndex: sides.right)
                }
                // 书脊：一条 1pt 细线，无阴影
                .overlay(SpineLineView(theme: theme))
            }

            if showDrawing {
                SpreadDrawingImage(book: book,
                                   spreadIndex: spread.index,
                                   size: spreadSize,
                                   revision: drawingRevision)
            }
        }
        .frame(width: spreadSize.width, height: spreadSize.height)
        .clipped()
    }

    @ViewBuilder
    private func slot(pageIndex: Int?) -> some View {
        if let pageIndex, book.pages.indices.contains(pageIndex) {
            PageContentView(page: book.pages[pageIndex],
                            size: CGSize(width: pageWidth, height: pageHeight),
                            theme: theme)
        } else {
            PaperView(theme: theme)
                .frame(width: pageWidth, height: pageHeight)
        }
    }
}

// MARK: - 单页渲染

/// 单页 = 跨页裁一半。翻到同一个跨页的左右页，笔迹位置天然对齐。
struct SinglePageView: View {
    let book: Book
    let pageIndex: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let drawingRevision: Int
    let showDrawing: Bool
    let theme: ReaderTheme

    /// 单页模式下要不要显示纸张边缘的描边
    var bordered: Bool = true

    var body: some View {
        Color.clear
            .frame(width: pageWidth, height: pageHeight)
            .overlay(alignment: .topLeading) {
                if let spread = SpreadLayout.spread(containingPage: pageIndex, in: book) {
                    let sides = SpreadLayout.visualSides(of: spread,
                                                         binding: book.bindingDirection)
                    let isRightSide = sides.right == pageIndex

                    SpreadCanvasView(book: book,
                                     spread: spread,
                                     pageWidth: pageWidth,
                                     pageHeight: pageHeight,
                                     drawingRevision: drawingRevision,
                                     showDrawing: showDrawing,
                                     theme: theme)
                        .offset(x: isRightSide ? -pageWidth : 0)
                } else {
                    PaperView(theme: theme)
                        .frame(width: pageWidth, height: pageHeight)
                }
            }
            .clipped()
            .overlay {
                if bordered {
                    Rectangle()
                        .stroke(PaperStyle.border, lineWidth: 0.5)
                }
            }
    }
}
