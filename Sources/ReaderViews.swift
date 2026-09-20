import SwiftUI
import PencilKit

// MARK: - 单页底图

struct PageContentView: View {
    let page: Page
    let size: CGSize
    let theme: ReaderTheme    // ← 必须有这一行

    var body: some View {
        ZStack {
            PaperView()

            if let name = page.imageFileName {
                StoredImage(name: name) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(page.transform.scale)
                        .offset(x: page.transform.offsetX, y: page.transform.offsetY)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - 跨页渲染（底图 + 笔迹）

/// 整个跨页作为一块画布渲染。单页模式只是裁它的一半 —— 保证坐标完全一致。
struct SpreadCanvasView: View {
    let book: Book
    let spread: Spread
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let drawingRevision: Int
    let showDrawing: Bool

    private var spreadSize: CGSize {
        CGSize(width: pageWidth * 2, height: pageHeight)
    }

    var body: some View {
        ZStack {
            if let idx = spread.fullSpreadPageIndex, book.pages.indices.contains(idx) {
                PageContentView(page: book.pages[idx], size: spreadSize)
            } else {
                let sides = SpreadLayout.visualSides(of: spread, binding: book.bindingDirection)
                HStack(spacing: 0) {
                    slot(pageIndex: sides.left)
                    slot(pageIndex: sides.right)
                }
                .overlay(SpineView())
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
                            size: CGSize(width: pageWidth, height: pageHeight))
        } else {
            PaperView()
                .frame(width: pageWidth, height: pageHeight)
        }
    }
}

// MARK: - 单页渲染

/// 单页 = 跨页裁一半。笔迹坐标天然对齐。
struct SinglePageView: View {
    let book: Book
    let pageIndex: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let drawingRevision: Int
    let showDrawing: Bool

    var body: some View {
        Color.clear
            .frame(width: pageWidth, height: pageHeight)
            .overlay(alignment: .topLeading) {
                if let spread = SpreadLayout.spread(containingPage: pageIndex, in: book) {
                    let sides = SpreadLayout.visualSides(of: spread,
                                                         binding: book.bindingDirection)
                    let showRight = sides.right == pageIndex
                    SpreadCanvasView(book: book,
                                     spread: spread,
                                     pageWidth: pageWidth,
                                     pageHeight: pageHeight,
                                     drawingRevision: drawingRevision,
                                     showDrawing: showDrawing)
                        .offset(x: showRight ? -pageWidth : 0)
                } else {
                    PaperView()
                        .frame(width: pageWidth, height: pageHeight)
                }
            }
            .clipped()
    }
}
