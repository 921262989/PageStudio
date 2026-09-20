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

// MARK: - 大纲条目

struct OutlineItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = "新条目"
    /// 0 = 一级，1 = 二级
    var level: Int = 0
    /// 跳转目标页（从 0 计数）
    var pageIndex: Int = 0
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
    /// 纯色封面配色
    var coverStyle: CoverStyle = .indigo
    /// 自定义封面图片文件名
    var customCoverImage: String? = nil
    /// 目录大纲
    var outline: [OutlineItem] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// ⚠️ 线性页面列表是「唯一真实来源」。
    /// 跨页配对由算法实时算出，绝不单独落库。
    var pages: [Page] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, title, bindingDirection, defaultViewMode, pageAspectRatio
        case coverPageAlone, coverStyle, customCoverImage, outline
        case createdAt, updatedAt, pages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未命名画册"
        bindingDirection = try c.decodeIfPresent(BindingDirection.self,
                                                 forKey: .bindingDirection) ?? .leftToRight
        defaultViewMode = try c.decodeIfPresent(ViewMode.self,
                                                forKey: .defaultViewMode) ?? .spread
        pageAspectRatio = try c.decodeIfPresent(Double.self,
                                                forKey: .pageAspectRatio) ?? 1.414
        coverPageAlone = try c.decodeIfPresent(Bool.self, forKey: .coverPageAlone) ?? false
        coverStyle = try c.decodeIfPresent(CoverStyle.self, forKey: .coverStyle) ?? .indigo
        customCoverImage = try c.decodeIfPresent(String.self, forKey: .customCoverImage)
        outline = try c.decodeIfPresent([OutlineItem].self, forKey: .outline) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        pages = try c.decodeIfPresent([Page].self, forKey: .pages) ?? []
    }
}

// MARK: - 跨页

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

    static func spreads(for book: Book) -> [Spread] {
        let pages = book.pages
        var result: [Spread] = []
        var cursor = 0
        var index = 0

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

        while cursor < pages.count {
            if pages[cursor].occupiesSpread {
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

    static func spreadIndex(containingPage pageIndex: Int, in book: Book) -> Int {
        spreads(for: book).first(where: { $0.pageIndices.contains(pageIndex) })?.index ?? 0
    }

    static func spread(containingPage pageIndex: Int, in book: Book) -> Spread? {
        spreads(for: book).first(where: { $0.pageIndices.contains(pageIndex) })
    }

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
    var pencilOnlyDrawMode: Bool = true
    var autoAppendPage: Bool = true
    var edgeTapTurn: Bool = true
    var zoomPersistOnTurn: Bool = true
    var pageTurnSound: Bool = false
    var pinchThreshold: Double = 0.15
    var readerTheme: ReaderTheme = .classic

    // 手势总开关
    var gesturesEnabled: Bool = true
    var twoFingerUndo: Bool = true
    var twoFingerLongPressUndo: Bool = true
    var threeFingerRedo: Bool = true
    var fourFingerClear: Bool = true
    var longPressEyedropper: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case pencilOnlyDrawMode, autoAppendPage, edgeTapTurn
        case zoomPersistOnTurn, pageTurnSound, pinchThreshold, readerTheme
        case gesturesEnabled, twoFingerUndo, twoFingerLongPressUndo
        case threeFingerRedo, fourFingerClear, longPressEyedropper
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pencilOnlyDrawMode = try c.decodeIfPresent(Bool.self,
                                                   forKey: .pencilOnlyDrawMode) ?? true
        autoAppendPage = try c.decodeIfPresent(Bool.self,
                                               forKey: .autoAppendPage) ?? true
        edgeTapTurn = try c.decodeIfPresent(Bool.self, forKey: .edgeTapTurn) ?? true
        zoomPersistOnTurn = try c.decodeIfPresent(Bool.self,
                                                  forKey: .zoomPersistOnTurn) ?? true
        pageTurnSound = try c.decodeIfPresent(Bool.self, forKey: .pageTurnSound) ?? false
        pinchThreshold = try c.decodeIfPresent(Double.self,
                                               forKey: .pinchThreshold) ?? 0.15
        readerTheme = try c.decodeIfPresent(ReaderTheme.self,
                                            forKey: .readerTheme) ?? .classic
        gesturesEnabled = try c.decodeIfPresent(Bool.self,
                                                forKey: .gesturesEnabled) ?? true
        twoFingerUndo = try c.decodeIfPresent(Bool.self,
                                              forKey: .twoFingerUndo) ?? true
        twoFingerLongPressUndo = try c.decodeIfPresent(
            Bool.self, forKey: .twoFingerLongPressUndo) ?? true
        threeFingerRedo = try c.decodeIfPresent(Bool.self,
                                                forKey: .threeFingerRedo) ?? true
        fourFingerClear = try c.decodeIfPresent(Bool.self,
                                                forKey: .fourFingerClear) ?? true
        longPressEyedropper = try c.decodeIfPresent(
            Bool.self, forKey: .longPressEyedropper) ?? true
    }
}
