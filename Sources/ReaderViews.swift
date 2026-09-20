import SwiftUI
import PencilKit

// MARK: - 单页底图

struct PageContentView: View {
    let page: Page
    let size: CGSize
    let theme: ReaderTheme

    /// 这本书的内页样式
    var ruleStyle: PageRuleStyle = .blank

    var body: some View {
        // ⚠️ 位移存的是逻辑坐标（页高 = 1000），这里换算成当前屏幕点
        let k = size.height / DrawingGeometry.logicalPageHeight

        ZStack {
            PaperView(theme: theme)

            // 内页样式：画在纸上、图片下面
            if ruleStyle.kind != .none {
                PageRuleLayer(style: ruleStyle, pageSize: size)
            }

            if let name = page.imageFileName {
                StoredImage(name: name) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(page.transform.scale)
                        .offset(x: page.transform.offsetX * k,
                                y: page.transform.offsetY * k)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

// MARK: - 跨页渲染（底图 + 笔迹）

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

    private var ruleStyle: PageRuleStyle {
        PageRuleStore.load(for: book.id)
    }

    var body: some View {
        ZStack {
            if let idx = spread.fullSpreadPageIndex, book.pages.indices.contains(idx) {
                PageContentView(page: book.pages[idx],
                                size: spreadSize,
                                theme: theme,
                                ruleStyle: ruleStyle)
            } else {
                let sides = SpreadLayout.visualSides(of: spread,
                                                     binding: book.bindingDirection)
                HStack(spacing: 0) {
                    slot(pageIndex: sides.left)
                    slot(pageIndex: sides.right)
                }
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
                            theme: theme,
                            ruleStyle: ruleStyle)
        } else {
            ZStack {
                PaperView(theme: theme)
                if ruleStyle.kind != .none {
                    PageRuleLayer(style: ruleStyle,
                                  pageSize: CGSize(width: pageWidth,
                                                   height: pageHeight))
                }
            }
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
                    let rule = PageRuleStore.load(for: book.id)
                    ZStack {
                        PaperView(theme: theme)
                        if rule.kind != .none {
                            PageRuleLayer(style: rule,
                                          pageSize: CGSize(width: pageWidth,
                                                           height: pageHeight))
                        }
                    }
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
