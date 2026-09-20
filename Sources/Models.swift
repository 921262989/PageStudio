import Foundation
import CoreGraphics

// MARK: - 翻页方向

enum BindingDirection: String, Codable, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: return "左开本"
        case .rightToLeft: return "右开本"
        }
    }
}

// MARK: - 浏览模式

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case single
    case spread

    var id: String { rawValue }
    var displayName: String { self == .single ? "单页" : "双页" }
}

// MARK: - 页面

enum PageKind: String, Codable, Hashable {
    case blank
    case image
}

/// 图片适配参数。非破坏性：只存参数，绝不修改原图。
struct PageTransform: Codable, Hashable {
    var scale: Double = 1.0
    var offsetX: Double = 0.0
    var offsetY: Double = 0.0
    var cropRect: CGRect? = nil

    static let identity = PageTransform()
}

struct Page: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: PageKind = .blank
    var imageFileName: String? = nil
    var transform: PageTransform = .identity
    /// 是否占满整个跨页（"两页一张"）
    var occupiesSpread: Bool = false

    static func blank() -> Page { Page() }

    static func image(fileName: String, occupiesSpread: Bool = false) -> Page {
        Page(kind: .image,
             imageFileName: fileName,
             transform: .identity,
             occupiesSpread: occupiesSpread)
    }
}

// MARK: - 画册

struct Book: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = "未命名画册"
    var bindingDirection: BindingDirection = .leftToRight
    var defaultViewMode: ViewMode = .spread
    /// 单页的高 / 宽。A5 ≈ 1.414
    var pageAspectRatio: Double = 1.414
    var coverPageAlone: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// ⚠️ 线性页面列表是「唯一真实来源」。
    /// 跨页配对由算法实时算出，绝不单独落库。
    var pages: [Page] = []

    var coverImageFileName: String? {
        pages.first(where: { $0.imageFileName != nil })?.imageFileName
    }
}

// MARK: - 跨页

/// 一个跨页（阅读单位 + 绘制单位）。由 Book.pages 实时计算，不落库。
struct Spread: Identifiable, Hashable {
    let index: Int
    let leftPageIndex: Int?
    let rightPageIndex: Int?
    let fullSpreadPageIndex: Int?

    var id: Int { index }

    var pageIndices: [Int] {
        [leftPageIndex, rightPageIndex, fullSpreadPageIndex].compactMap { $0 }
    }
}

enum SpreadLayout {

    /// 把线性页面列表切成跨页序列
    static func spreads(for book: Book) -> [Spread] {
        let pages = book.pages
        var result: [Spread] = []
        var cursor = 0
        var index = 0

        // 1) 首页单独作封面
        if book.coverPageAlone, !pages.isEmpty {
            if pages[0].occupiesSpread {
                result.append(Spread(index: 0,
                                     leftPageIndex: nil,
                                     rightPageIndex: nil,
                                     fullSpreadPageIndex: 0))
            } else {
                result.append(Spread(index: 0,
                                     leftPageIndex: nil,
                                     rightPageIndex: 0,
                                     fullSpreadPageIndex: nil))
            }
            cursor = 1
            index = 1
        }

        // 2) 两两配对
        while cursor < pages.count {
            if pages[cursor].occupiesSpread {
                // 占满跨页的图：独占一个跨页
                result.append(Spread(index: index,
                                     leftPageIndex: nil,
                                     rightPageIndex: nil,
                                     fullSpreadPageIndex: cursor))
                cursor += 1
            } else if cursor + 1 < pages.count, !pages[cursor + 1].occupiesSpread {
                result.append(Spread(index: index,
                                     leftPageIndex: cursor,
                                     rightPageIndex: cursor + 1,
                                     fullSpreadPageIndex: nil))
                cursor += 2
            } else {
                result.append(Spread(index: index,
                                     leftPageIndex: cursor,
                                     rightPageIndex: nil,
                                     fullSpreadPageIndex: nil))
                cursor += 1
            }
            index += 1
        }

        if result.isEmpty {
            result.append(Spread(index: 0,
                                 leftPageIndex: nil,
                                 rightPageIndex: nil,
                                 fullSpreadPageIndex: nil))
        }
        return result
    }

    /// 给定页码，找出它属于哪个跨页
    static func spreadIndex(containingPage pageIndex: Int, in book: Book) -> Int {
        spreads(for: book).first(where: { $0.pageIndices.contains(pageIndex) })?.index ?? 0
    }

    /// 按翻页方向决定左右两个槽位各放哪一页
    static func visualSides(of spread: Spread,
                            binding: BindingDirection) -> (left: Int?, right: Int?) {
        switch binding {
        case .leftToRight:
            return (spread.leftPageIndex, spread.rightPageIndex)
        case .rightToLeft:
            return (spread.rightPageIndex, spread.leftPageIndex)
        }
    }
}

// MARK: - 设置

struct AppSettings: Codable, Equatable {
    /// true = 仅 Apple Pencil 可绘制；false = 手指 + Pencil 都可绘制
    var pencilOnlyDrawMode: Bool = true
    var autoAppendPage: Bool = true
    var edgeTapTurn: Bool = true
    var zoomPersistOnTurn: Bool = true
    var pageTurnSound: Bool = false
    /// 双指「平移 vs 缩放」判定阈值
    var pinchThreshold: Double = 0.15
}
