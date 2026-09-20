import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import PencilKit

// MARK: - 工具弹窗

enum ToolPopover: Identifiable, Equatable {
    case brush(PenKind)
    case eraser

    var id: String {
        switch self {
        case .brush(let k): return "brush-\(k.rawValue)"
        case .eraser:       return "eraser"
        }
    }
}

@MainActor
struct BookReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @StateObject private var layerStore = LayerStore()

    let bookID: UUID

    @State private var position: Double = 0
    @State private var viewMode: ViewMode = .spread
    @State private var didInitialize = false

    @State private var isDraggingPage = false
    @State private var dragStartPosition: Double = 0

    private let pageTurnDistanceFactor: CGFloat = 0.20
    private let minPageTurnDistance: CGFloat = 96
    private let longJumpThreshold: Double = 3.0

    @State private var fastJumpActive = false

    @State private var isPenActive = false
    @State private var activeTool: ActiveTool = .brush(.pen)
    @State private var penColor: Color = Color(white: 0.06)
    @State private var eraserKind: EraserKind = .precise
    @State private var eraserWidth: EraserWidth = .medium

    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0
    @State private var zoomResetTrigger = 0
    @State private var zoomInTrigger = 0
    @State private var zoomOutTrigger = 0
    @State private var zoomLevel: CGFloat = 1

    @State private var activePopover: ToolPopover?
    @State private var brushBarCollapsed = false
    @State private var saveColorPulse = false

    @State private var activeLayerIDs: [String: UUID] = [:]

    @State private var showThumbnails = false
    @State private var showOutline = false
    @State private var showLayers = false

    /// 调整范围的目标页
    @State private var adjustPageIndex: Int? = nil
    @State private var showImageAdjust = false

    /// 替换图片的目标页（导入照片到当前页）
    @State private var replacePageIndex: Int? = nil

    /// 浮出的「左页 / 右页」选择
    @State private var choiceIndices: [Int] = []
    @State private var choiceTitle = ""
    @State private var choiceIsReplace = false
    @State private var showChoice = false

    @State private var didAutoAppend = false

    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importOccupiesSpread = false
    @State private var importMessage: String? = nil

    @State private var pdfImportProgress: Double? = nil
    @State private var pdfImportTotal = 0
    @State private var pdfImportDone = 0

    private static let paperCache = NSCache<NSString, UIImage>()

    private var book: Book? { library.book(id: bookID) }
    private var settings: AppSettings { settingsStore.settings }
    private var theme: ReaderTheme { settings.readerTheme }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReaderBackground(theme: theme)

                if let book {
                    main(book: book, container: geo.size)
                } else {
                    Text("这本画册已被删除")
                        .foregroundStyle(.secondary)
                }

                if let progress = pdfImportProgress {
                    importingOverlay(progress: progress)
                }
            }
            .onAppear { initialize(container: geo.size) }
        }
        .navigationTitle(book?.title ?? "画册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoItems,
                      maxSelectionCount: 200,
                      matching: .images)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }

            let target = replacePageIndex
            replacePageIndex = nil

            if let target {
                Task { await replacePhoto(items, at: target) }
            } else {
                Task { await importFromPhotos(items) }
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: false) { result in
            importFromFiles(result)
        }
        .sheet(isPresented: $showThumbnails) {
            if let book {
                ThumbnailPanelView(book: book,
                                   currentPageIndex: currentPageIndex(book: book),
                                   theme: theme,
                                   onSelect: { pageIdx in
                                       jump(toPage: pageIdx, book: book)
                                   },
                                   onChange: { updated in
                                       library.update(updated)
                                       clampPosition()
                                   })
            }
        }
        .sheet(isPresented: $showOutline) {
            if let book {
                OutlinePanelView(book: book,
                                 currentPageIndex: currentPageIndex(book: book),
                                 onJump: { pageIdx in
                                     jump(toPage: pageIdx, book: book)
                                 },
                                 onChange: { updated in
                                     library.update(updated)
                                 })
            }
        }
        .sheet(isPresented: $showLayers) {
            if let book {
                let sIndex = spreadIndexForUnit(currentUnit(book: book), book: book)
                LayerPanelView(book: book,
                               spreadIndex: sIndex,
                               layerStore: layerStore,
                               activeLayerID: activeLayerBinding(book: book,
                                                                 spreadIndex: sIndex))
            }
        }
        .sheet(isPresented: $showImageAdjust) {
            if let book,
               let pageIndex = adjustPageIndex,
               book.pages.indices.contains(pageIndex) {
                ImageAdjustView(page: book.pages[pageIndex],
                                book: book) { newTransform in
                    guard var updated = library.book(id: bookID),
                          updated.pages.indices.contains(pageIndex) else { return }
                    updated.pages[pageIndex].transform = newTransform
                    library.update(updated)
                    Self.paperCache.removeAllObjects()
                }
            }
        }
        .confirmationDialog(choiceTitle,
                            isPresented: $showChoice,
                            titleVisibility: .visible) {
            ForEach(choiceIndices, id: \.self) { idx in
                Button("第 \(idx + 1) 页") {
                    if choiceIsReplace {
                        beginReplacePhoto(at: idx)
                    } else {
                        adjustPageIndex = idx
                        showImageAdjust = true
                    }
                }
            }
            Button("取消", role: .cancel) { }
        }
        .preferredColorScheme(.dark)
        .onChange(of: library.book(id: bookID)?.pages.count ?? 0) { _ in
            clampPosition()
        }
        .onChange(of: isPenActive) { active in
            Self.paperCache.removeAllObjects()

            if active {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    brushBarCollapsed = false
                }
            } else {
                activePopover = nil
            }
        }
        .alert("提示",
               isPresented: Binding(
                    get: { importMessage != nil },
                    set: { if !$0 { importMessage = nil } }
               )) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    @ViewBuilder
    private func importingOverlay(progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .frame(width: 220)
                Text("正在导入 PDF")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(pdfImportDone) / \(pdfImportTotal) 页")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(28)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - 主布局

    @ViewBuilder
    private func main(book: Book, container: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                GeometryReader { inner in
                    bookArea(book: book, available: inner.size)
                }

                if !isPenActive && !book.pages.isEmpty {
                    bottomBar(book: book)
                }
            }
            .frame(width: container.width, height: container.height)

            if isPenActive {
                VStack(spacing: 10) {
                    if let item = activePopover {
                        toolPanel(item)
                            .transition(.scale(scale: 0.94, anchor: .bottom)
                                .combined(with: .opacity))
                    }

                    penToolbar
                        .padding(.horizontal, 10)
                }
                .padding(.bottom, 12)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86),
                   value: activePopover)
    }

    @ViewBuilder
    private func toolPanel(_ item: ToolPopover) -> some View {
        switch item {
        case .brush(let kind):
            BrushSettingsPanel(settingsStore: settingsStore,
                               kind: kind,
                               color: penColor,
                               onClose: { activePopover = nil })
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)

        case .eraser:
            EraserPanel(kind: $eraserKind,
                        width: $eraserWidth,
                        onClose: { activePopover = nil })
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        }
    }

    // MARK: - 书籍区域

    @ViewBuilder
    private func bookArea(book: Book, available: CGSize) -> some View {
        let size = readerSize(in: available, book: book)
        let count = readerUnitCount(book: book)
        let maxPos = Double(max(count - 1, 0))
        let clamped = min(max(position, 0), maxPos)
        let from = Int(floor(clamped))
        let frac = CGFloat(clamped - Double(from))

        ZStack {
            if book.pages.isEmpty {
                emptyHint
            } else if fastJumpActive {
                quickJumpScene(book: book, size: size)
            } else if from + 1 < count && !(isPenActive && frac < 0.002) {
                spreadOrSingleFlipping(book: book,
                                       size: size,
                                       from: from,
                                       progress: frac)
            } else {
                stableScene(book: book, size: size, index: from)
            }
        }
        .frame(width: available.width, height: available.height)
        .contentShape(Rectangle())
        .gesture(turnGesture(size: size, book: book))
        .simultaneousGesture(edgeTapGesture(available: available, book: book))
    }

    @ViewBuilder
    private func quickJumpScene(book: Book, size: ReaderSize) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 38))
                .foregroundStyle(Color.black.opacity(0.28))
            Text(unitLabel(at: position, book: book))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.45))
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
        .background(PaperView(theme: theme))
        .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                    style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous)
                .stroke(PaperStyle.border, lineWidth: 0.5)
        )
    }

    private func unitLabel(at value: Double, book: Book) -> String {
        if viewMode == .spread {
            let count = max(SpreadLayout.spreads(for: book).count, 1)
            let idx = min(max(Int(value.rounded()), 0), count - 1)
            let start = idx * 2 + 1
            let end = min(start + 1, book.pages.count)
            return "跨页 \(start)-\(end)"
        } else {
            let count = max(book.pages.count, 1)
            let idx = min(max(Int(value.rounded()), 0), count - 1)
            return "第 \(idx + 1) / \(book.pages.count) 页"
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("这本画册还没有页面")
                .foregroundStyle(.secondary)
            Text("点右上角 ⋯ 导入图片或 PDF")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 静止场景

    @ViewBuilder
    private func stableScene(book: Book, size: ReaderSize, index: Int) -> some View {
        let sIndex = spreadIndexForUnit(index, book: book)
        let layers = layerStore.layers(bookId: book.id, spreadIndex: sIndex)
        let activeID = activeLayerID(book: book, spreadIndex: sIndex)
        let editingThisUnit = isPenActive && index == currentUnit(book: book)
        let spreadSize = CGSize(width: size.pageWidth * 2, height: size.pageHeight)

        ZStack {
            SpreadCanvasView(book: book,
                             spread: spreadForUnit(index, book: book) ?? emptySpread,
                             pageWidth: size.pageWidth,
                             pageHeight: size.pageHeight,
                             drawingRevision: 0,
                             showDrawing: false,
                             theme: theme)
                .allowsHitTesting(false)

            ForEach(layers) { meta in
                if editingThisUnit && meta.id == activeID {
                    if meta.isVisible {
                        drawingCanvas(book: book, unitIndex: index, size: size,
                                      spreadIndex: sIndex, layerID: meta.id)
                            .opacity(meta.clampedOpacity)
                    }
                } else if meta.isVisible {
                    InkImageView(drawing: layerStore.drawing(bookId: book.id,
                                                             spreadIndex: sIndex,
                                                             layerID: meta.id),
                                 size: spreadSize,
                                 revision: layerStore.version,
                                 opacity: meta.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
        .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                    style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous)
                .stroke(PaperStyle.border, lineWidth: 0.5)
        )
    }

    private var emptySpread: Spread {
        Spread(index: 0, leftPageIndex: nil, rightPageIndex: nil,
               fullSpreadPageIndex: nil)
    }

    private func spreadForUnit(_ index: Int, book: Book) -> Spread? {
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            guard spreads.indices.contains(index) else { return nil }
            return spreads[index]
        } else {
            return SpreadLayout.spread(containingPage: index, in: book)
        }
    }

    // MARK: - 翻页场景（翻动的那张纸放在裁剪层之外，可以探出书框）

    @ViewBuilder
    private func spreadOrSingleFlipping(book: Book, size: ReaderSize,
                                        from: Int, progress: CGFloat) -> some View {
        if viewMode == .spread {
            spreadFlippingScene(book: book, size: size,
                                from: from, progress: progress)
        } else {
            singleFlippingScene(book: book, size: size,
                                from: from, progress: progress)
        }
    }

    @ViewBuilder
    private func spreadFlippingScene(book: Book, size: ReaderSize,
                                     from: Int, progress: CGFloat) -> some View {
        let spreads = SpreadLayout.spreads(for: book)
        let to = from + 1
        let pw = size.pageWidth
        let ph = size.pageHeight

        if spreads.indices.contains(from), spreads.indices.contains(to) {
            let fromSpread = spreads[from]
            let toSpread = spreads[to]
            let fromSides = SpreadLayout.visualSides(of: fromSpread,
                                                     binding: book.bindingDirection)
            let toSides = SpreadLayout.visualSides(of: toSpread,
                                                   binding: book.bindingDirection)

            ZStack {
                // ① 静止层：目标跨页，裁在书框里
                ZStack {
                    SpreadCanvasView(book: book,
                                     spread: toSpread,
                                     pageWidth: pw,
                                     pageHeight: ph,
                                     drawingRevision: layerStore.version,
                                     showDrawing: false,
                                     theme: theme)
                        .frame(width: pw * 2, height: ph)
                        .allowsHitTesting(false)
                        .overlay {
                            bakedLayers(book: book,
                                        spreadIndex: to,
                                        size: CGSize(width: pw * 2, height: ph))
                        }

                    pageOrPaper(book: book, index: fromSides.left, size: size)
                        .position(x: pw / 2, y: ph / 2)
                }
                .frame(width: pw * 2, height: ph)
                .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: bookCornerRadius,
                                     style: .continuous)
                        .stroke(PaperStyle.border, lineWidth: 0.5)
                )

                // ② 翻动的那张纸：不在裁剪层里，转动时能探出书框
                FlipCard(front: pageOrPaper(book: book, index: fromSides.right,
                                            size: size),
                         back: pageOrPaper(book: book, index: toSides.left,
                                           size: size),
                         angle: -Double(progress) * 180,
                         anchor: .leading,
                         perspective: 0.32,
                         dimming: PaperStyle.flipDimming,
                         paperColor: PaperStyle.fill,
                         borderColor: PaperStyle.border)
                    .frame(width: pw, height: ph)
                    .position(x: pw * 1.5, y: ph / 2)
            }
            .frame(width: pw * 2, height: ph)
        }
    }

    @ViewBuilder
    private func singleFlippingScene(book: Book, size: ReaderSize,
                                     from: Int, progress: CGFloat) -> some View {
        let pw = size.pageWidth
        let ph = size.pageHeight
        let to = from + 1

        if book.pages.indices.contains(from), book.pages.indices.contains(to) {
            ZStack {
                // ① 静止层
                ZStack {
                    SinglePageView(book: book,
                                   pageIndex: to,
                                   pageWidth: pw,
                                   pageHeight: ph,
                                   drawingRevision: layerStore.version,
                                   showDrawing: false,
                                   theme: theme)
                        .allowsHitTesting(false)
                        .overlay {
                            pageInkOverlay(book: book,
                                           pageIndex: to,
                                           size: size)
                        }
                }
                .frame(width: pw, height: ph)
                .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: bookCornerRadius,
                                     style: .continuous)
                        .stroke(PaperStyle.border, lineWidth: 0.5)
                )

                // ② 翻动的纸
                FlipCard(front: pageOrPaper(book: book, index: from, size: size),
                         back: pageOrPaper(book: book, index: to, size: size),
                         angle: -Double(progress) * 180,
                         anchor: .leading,
                         perspective: 0.32,
                         dimming: PaperStyle.flipDimming,
                         paperColor: PaperStyle.fill,
                         borderColor: PaperStyle.border)
                    .frame(width: pw, height: ph)
            }
            .frame(width: pw, height: ph)
        }
    }

    @ViewBuilder
    private func bakedLayers(book: Book, spreadIndex: Int, size: CGSize) -> some View {
        let layers = layerStore.layers(bookId: book.id, spreadIndex: spreadIndex)
        ZStack {
            ForEach(layers) { meta in
                if meta.isVisible {
                    InkImageView(drawing: layerStore.drawing(bookId: book.id,
                                                             spreadIndex: spreadIndex,
                                                             layerID: meta.id),
                                 size: size,
                                 revision: layerStore.version,
                                 opacity: meta.opacity)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func pageInkOverlay(book: Book, pageIndex: Int, size: ReaderSize) -> some View {
        let sIndex = SpreadLayout.spreadIndex(containingPage: pageIndex, in: book)
        let isRight = isRightPage(unitIndex: pageIndex, book: book)

        ZStack(alignment: .topLeading) {
            bakedLayers(book: book,
                        spreadIndex: sIndex,
                        size: CGSize(width: size.pageWidth * 2,
                                     height: size.pageHeight))
                .offset(x: isRight ? -size.pageWidth : 0)
        }
        .frame(width: size.pageWidth, height: size.pageHeight, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func pageOrPaper(book: Book, index: Int?, size: ReaderSize) -> some View {
        if let index, book.pages.indices.contains(index) {
            SinglePageView(book: book,
                           pageIndex: index,
                           pageWidth: size.pageWidth,
                           pageHeight: size.pageHeight,
                           drawingRevision: layerStore.version,
                           showDrawing: false,
                           theme: theme)
                .overlay {
                    pageInkOverlay(book: book, pageIndex: index, size: size)
                }
                .allowsHitTesting(false)
        } else {
            PaperView(theme: theme)
                .frame(width: size.pageWidth, height: size.pageHeight)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 尺寸

    struct ReaderSize {
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var containerWidth: CGFloat
        var containerHeight: CGFloat
    }

    private func readerSize(in container: CGSize, book: Book) -> ReaderSize {
        let ratio = max(book.pageAspectRatio, 0.4)

        let hInset: CGFloat = isPenActive ? 0 : 6
        let vInset: CGFloat = isPenActive ? 0 : (viewMode == .spread ? 8 : 12)

        let availW = max(container.width - hInset * 2, 100)
        let availH = max(container.height - vInset * 2, 100)

        var pw: CGFloat
        var ph: CGFloat

        if viewMode == .spread {
            ph = availH
            pw = ph / ratio
            if pw * 2 > availW {
                pw = availW / 2
                ph = pw * ratio
            }
        } else {
            ph = availH
            pw = ph / ratio
            if pw > availW {
                pw = availW
                ph = pw * ratio
            }
        }

        return ReaderSize(pageWidth: pw,
                          pageHeight: ph,
                          containerWidth: viewMode == .spread ? pw * 2 : pw,
                          containerHeight: ph)
    }

    private var bookCornerRadius: CGFloat {
        isPenActive ? 6 : 14
    }

    private func readerUnitCount(book: Book) -> Int {
        viewMode == .spread ? SpreadLayout.spreads(for: book).count : book.pages.count
    }

    private func currentUnit(book: Book) -> Int {
        let count = readerUnitCount(book: book)
        return min(max(Int(position.rounded()), 0), max(count - 1, 0))
    }

    // MARK: - 图层辅助

    private func spreadIndexForUnit(_ index: Int, book: Book) -> Int {
        if viewMode == .spread {
            return index
        } else {
            return SpreadLayout.spreadIndex(containingPage: index, in: book)
        }
    }

    private func activeLayerID(book: Book, spreadIndex: Int) -> UUID {
        let layers = layerStore.layers(bookId: book.id, spreadIndex: spreadIndex)
        let key = "\(spreadIndex)"

        if let cached = activeLayerIDs[key],
           layers.contains(where: { $0.id == cached }) {
            return cached
        }
        return layers.last?.id ?? UUID()
    }

    private func activeLayerBinding(book: Book, spreadIndex: Int) -> Binding<UUID> {
        Binding(
            get: { activeLayerID(book: book, spreadIndex: spreadIndex) },
            set: { activeLayerIDs["\(spreadIndex)"] = $0 }
        )
    }

    // MARK: - 当前页 / 本跨页的页列表

    private func currentPageIndex(book: Book) -> Int {
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let clamped = min(max(currentUnit(book: book), 0),
                              max(spreads.count - 1, 0))
            return spreads[clamped].pageIndices.first ?? 0
        } else {
            return min(max(currentUnit(book: book), 0),
                       max(book.pages.count - 1, 0))
        }
    }

    /// 当前「看得见的这一页」有哪些页。
    /// 双页模式下是左页 + 右页两页。
    private func visiblePageIndices(book: Book) -> [Int] {
        let total = book.pages.count
        guard total > 0 else { return [] }

        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let idx = min(max(currentUnit(book: book), 0), max(spreads.count - 1, 0))
            let spread = spreads[idx]
            let sides = SpreadLayout.visualSides(of: spread,
                                                 binding: book.bindingDirection)
            var out: [Int] = []
            if let l = sides.left, l < total { out.append(l) }
            if let r = sides.right, r < total, r != sides.left { out.append(r) }
            return out
        } else {
            return [min(max(currentUnit(book: book), 0), total - 1)]
        }
    }

    /// 「把照片导入到当前页」和「调整本页范围」都先走这里：
    /// 只有一页就直接做，两页就先问用户选哪一页。
    private func chooseVisiblePage(book: Book,
                                   title: String,
                                   isReplace: Bool) {
        // ⚠️ 这里必须带参数标签 book:
        let indices = visiblePageIndices(book: book)
        guard !indices.isEmpty else { return }

        if indices.count == 1 {
            if isReplace {
                beginReplacePhoto(at: indices[0])
            } else {
                adjustPageIndex = indices[0]
                showImageAdjust = true
            }
            return
        }

        choiceIndices = indices
        choiceTitle = title
        choiceIsReplace = isReplace
        showChoice = true
    }

    private func beginReplacePhoto(at index: Int) {
        replacePageIndex = index
        showPhotoPicker = true
    }

    // MARK: - 绘制画布

    private func paperImage(book: Book, spreadIndex: Int,
                            logical: CGSize) -> UIImage? {
        let key = "paper-\(book.id.uuidString)-\(spreadIndex)"
            + "-\(Int(logical.width))x\(Int(logical.height))" as NSString

        if let cached = Self.paperCache.object(forKey: key) {
            return cached
        }

        let spreads = SpreadLayout.spreads(for: book)
        guard spreads.indices.contains(spreadIndex) else { return nil }

        let content = SpreadCanvasView(book: book,
                                       spread: spreads[spreadIndex],
                                       pageWidth: logical.width / 2,
                                       pageHeight: logical.height,
                                       drawingRevision: 0,
                                       showDrawing: false,
                                       theme: theme)
            .frame(width: logical.width, height: logical.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1.5
        renderer.isOpaque = false

        guard let image = renderer.uiImage else { return nil }
        Self.paperCache.setObject(image, forKey: key)
        return image
    }

    @ViewBuilder
    private func drawingCanvas(book: Book, unitIndex index: Int,
                               size: ReaderSize, spreadIndex: Int,
                               layerID: UUID) -> some View {
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
        let isSingle = (viewMode == .single)

        let displayViewport = isSingle
            ? CGSize(width: size.pageWidth, height: size.pageHeight)
            : CGSize(width: size.containerWidth, height: size.containerHeight)

        let showRightHalf = isSingle && isRightPage(unitIndex: index, book: book)
        let initialOffsetX: CGFloat = showRightHalf ? (logical.width / 2) : 0

        DrawingCanvas(
            canvasSize: logical,
            viewportSize: displayViewport,
            initialOffsetX: initialOffsetX,
            displaySize: CGSize(width: size.pageWidth * 2,
                                height: size.pageHeight),
            paperImage: paperImage(book: book,
                                   spreadIndex: spreadIndex,
                                   logical: logical),
            book: book,
            spreadIndex: spreadIndex,
            initialDrawing: layerStore.drawing(bookId: book.id,
                                               spreadIndex: spreadIndex,
                                               layerID: layerID),
            pencilOnly: settings.pencilOnlyDrawMode,
            tool: currentTool,
            toolSignature: toolSignature,
            undoTrigger: undoTrigger,
            redoTrigger: redoTrigger,
            clearTrigger: clearTrigger,
            zoomResetTrigger: zoomResetTrigger,
            zoomInTrigger: zoomInTrigger,
            zoomOutTrigger: zoomOutTrigger,
            gesturesEnabled: settings.gesturesEnabled,
            twoFingerUndo: settings.twoFingerUndo,
            twoFingerLongPressUndo: settings.twoFingerLongPressUndo,
            threeFingerRedo: settings.threeFingerRedo,
            fourFingerClear: settings.fourFingerClear,
            longPressEyedropper: settings.longPressEyedropper,
            pagePanEnabled: pagingEnabled && !fastJumpActive,
            pageTapEnabled: edgeTapActive,
            onPagePanChanged: { dx in
                turnDragChanged(dx, size: size, book: book)
            },
            onPagePanEnded: { dx, predicted in
                turnDragEnded(dx, predicted, size: size, book: book)
            },
            onPageTap: { x in
                handleEdgeTap(at: x, width: displayViewport.width, book: book)
            },
            onDrawingChanged: { newDrawing in
                layerStore.setDrawing(newDrawing,
                                      bookId: book.id,
                                      spreadIndex: spreadIndex,
                                      layerID: layerID)
                handleAutoAppend(book: book, spreadIndex: spreadIndex,
                                 drawing: newDrawing)
            },
            onDrawingStateChanged: { _ in },
            onPickColor: { picked in
                DispatchQueue.main.async {
                    penColor = picked
                    if activeTool.isEraser {
                        activeTool = .brush(.pen)
                    }
                }
            },
            onZoomChanged: { level in
                DispatchQueue.main.async {
                    if abs(zoomLevel - level) > 0.005 {
                        zoomLevel = level
                    }
                }
            }
        )
        .frame(width: displayViewport.width, height: displayViewport.height)
        .clipped()
    }

    // MARK: - 工具构造

    private var activeBrushKind: PenKind {
        activeTool.brushKind ?? .pen
    }

    private var currentTool: PKTool {
        switch activeTool {
        case .brush(let kind):
            let s = settingsStore.brushSettings(for: kind)
            let ui = brushUIColor(alpha: s.clampedOpacity)
            let width = s.clampedWidth * kind.widthMultiplier
            return PKInkingTool(kind.inkType, color: ui, width: width)

        case .eraser:
            if #available(iOS 16.4, *) {
                return PKEraserTool(eraserKind.pkType, width: eraserWidth.value)
            } else {
                return PKEraserTool(eraserKind.pkType)
            }
        }
    }

    private func brushUIColor(alpha: CGFloat) -> UIColor {
        let a = min(max(alpha, 0), 1)

        if let cg = penColor.cgColor,
           let comps = cg.components,
           !comps.isEmpty {

            if comps.count >= 3 {
                return UIColor(red: min(max(comps[0], 0), 1),
                               green: min(max(comps[1], 0), 1),
                               blue: min(max(comps[2], 0), 1),
                               alpha: a)
            }
            if comps.count == 2 {
                let g = min(max(comps[0], 0), 1)
                return UIColor(red: g, green: g, blue: g, alpha: a)
            }
        }
        return UIColor(penColor).withAlphaComponent(a)
    }

    private var toolSignature: String {
        switch activeTool {
        case .brush(let kind):
            let s = settingsStore.brushSettings(for: kind)
            return "brush|\(kind.rawValue)|\(stableColorKey(penColor))|\(s.width)|\(s.opacity)"
        case .eraser:
            return "eraser|\(eraserKind.rawValue)|\(eraserWidth.rawValue)"
        }
    }

    private func isRightPage(unitIndex index: Int, book: Book) -> Bool {
        guard let s = SpreadLayout.spread(containingPage: index, in: book) else {
            return false
        }
        return SpreadLayout.visualSides(of: s,
                                        binding: book.bindingDirection).right == index
    }

    // MARK: - 手势

    private var pagingEnabled: Bool {
        if !isPenActive { return true }
        if settings.pencilOnlyDrawMode { return true }
        return false
    }

    private var edgeTapActive: Bool {
        settings.edgeTapTurn && (!isPenActive || settings.pencilOnlyDrawMode)
    }

    private func pageTurnDistance(size: ReaderSize) -> CGFloat {
        max(size.containerWidth * pageTurnDistanceFactor, minPageTurnDistance)
    }

    private func turnGesture(size: ReaderSize, book: Book) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !isPenActive else { return }
                guard pagingEnabled, !fastJumpActive else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.1 else { return }

                if !isDraggingPage {
                    isDraggingPage = true
                    dragStartPosition = position
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                let turnDistance = pageTurnDistance(size: size)
                let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1
                let delta = Double(dx / turnDistance) * direction

                let count = readerUnitCount(book: book)
                let maxPos = Double(max(count - 1, 0))

                position = min(max(dragStartPosition + delta, 0), maxPos)
            }
            .onEnded { value in
                guard !isPenActive else { return }
                guard isDraggingPage else { return }
                isDraggingPage = false

                let count = readerUnitCount(book: book)
                let maxPos = Double(max(count - 1, 0))
                let turnDistance = pageTurnDistance(size: size)
                let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1

                let predictedDelta = Double(value.predictedEndTranslation.width
                                            / turnDistance) * direction
                let predicted = dragStartPosition + predictedDelta
                let target = min(max(predicted.rounded(), 0), maxPos)

                if abs(target - dragStartPosition) > longJumpThreshold {
                    quickJump(to: target, book: book)
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        position = target
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }

    private func edgeTapGesture(available: CGSize, book: Book) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard !isPenActive else { return }
                guard edgeTapActive, !fastJumpActive else { return }
                handleEdgeTap(at: value.location.x,
                              width: available.width,
                              book: book)
            }
    }

    private func turnDragChanged(_ dx: CGFloat, size: ReaderSize, book: Book) {
        guard pagingEnabled, !fastJumpActive else { return }

        if !isDraggingPage {
            isDraggingPage = true
            dragStartPosition = position
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        let turnDistance = pageTurnDistance(size: size)
        let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1
        let delta = Double(dx / turnDistance) * direction

        let count = readerUnitCount(book: book)
        let maxPos = Double(max(count - 1, 0))

        position = min(max(dragStartPosition + delta, 0), maxPos)
    }

    private func turnDragEnded(_ dx: CGFloat, _ predictedX: CGFloat,
                               size: ReaderSize, book: Book) {
        guard isDraggingPage else { return }
        isDraggingPage = false

        let count = readerUnitCount(book: book)
        let maxPos = Double(max(count - 1, 0))
        let turnDistance = pageTurnDistance(size: size)
        let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1

        let predictedDelta = Double(predictedX / turnDistance) * direction
        let predicted = dragStartPosition + predictedDelta
        let target = min(max(predicted.rounded(), 0), maxPos)

        if abs(target - dragStartPosition) > longJumpThreshold {
            quickJump(to: target, book: book)
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                position = target
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func handleEdgeTap(at x: CGFloat, width: CGFloat, book: Book) {
        guard edgeTapActive, !fastJumpActive, width > 1 else { return }

        if x < width * 0.16 {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                position = max(position - 1, 0)
            }
        } else if x > width * 0.84 {
            let maxPos = Double(max(readerUnitCount(book: book) - 1, 0))
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                position = min(position + 1, maxPos)
            }
        }
    }

    // MARK: - 位置

    private func clampPosition() {
        guard let book else { return }
        let maxPos = Double(max(readerUnitCount(book: book) - 1, 0))
        position = min(max(position, 0), maxPos)
        isDraggingPage = false
        fastJumpActive = false
    }

    private func initialize(container: CGSize) {
        guard !didInitialize, let book else { return }
        didInitialize = true
        let isPortrait = container.height > container.width
        viewMode = isPortrait ? .single : book.defaultViewMode
        position = 0
    }

    private func toggleViewMode() {
        guard let book else { return }
        let current = currentUnit(book: book)
        zoomResetTrigger += 1
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let clamped = min(max(current, 0), max(spreads.count - 1, 0))
            let firstPage = spreads[clamped].pageIndices.first ?? 0
            viewMode = .single
            position = Double(firstPage)
        } else {
            let sIndex = SpreadLayout.spreadIndex(containingPage: current, in: book)
            viewMode = .spread
            position = Double(sIndex)
        }
    }

    private func jump(toPage pageIdx: Int, book: Book) {
        isDraggingPage = false
        let target: Double = (viewMode == .spread)
            ? Double(SpreadLayout.spreadIndex(containingPage: pageIdx, in: book))
            : Double(pageIdx)

        if abs(target - position) > longJumpThreshold {
            quickJump(to: target, book: book)
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                position = target
            }
        }
    }

    private func quickJump(to target: Double, book: Book) {
        let maxPos = Double(max(readerUnitCount(book: book) - 1, 0))
        let clamped = min(max(target, 0), maxPos)

        fastJumpActive = true
        position = clamped
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            fastJumpActive = false
        }
    }

    // MARK: - 底部栏

    @ViewBuilder
    private func bottomBar(book: Book) -> some View {
        let count = readerUnitCount(book: book)
        let current = currentUnit(book: book)

        VStack(spacing: 4) {
            scrubber(book: book)

            HStack(spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        position = max(position - 1, 0)
                    }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(current <= 0)

                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        position = min(position + 1, Double(max(count - 1, 0)))
                    }
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(current >= count - 1)

                Spacer()

                Text(positionText(book: book))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.38), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func scrubber(book: Book) -> some View {
        let unitCount = max(readerUnitCount(book: book), 1)
        let maxPos = Double(max(unitCount - 1, 0))
        let progress: Double = maxPos > 0
            ? min(max(position, 0), maxPos) / maxPos
            : 0

        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(w * CGFloat(progress), 5), height: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !fastJumpActive {
                            fastJumpActive = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        let ratio = min(max(value.location.x / w, 0), 1)
                        position = min(max((Double(ratio) * maxPos).rounded(), 0), maxPos)
                    }
                    .onEnded { _ in
                        position = min(max(position.rounded(), 0), maxPos)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            fastJumpActive = false
                        }
                    }
            )
        }
        .frame(height: 20)
        .padding(.horizontal, 24)
    }

    private func positionText(book: Book) -> String {
        if viewMode == .spread {
            let count = SpreadLayout.spreads(for: book).count
            let clamped = min(max(currentUnit(book: book), 0), max(count - 1, 0))
            let start = clamped * 2 + 1
            let end = min(start + 1, book.pages.count)
            return "跨页 \(start)-\(end)"
        } else {
            let clamped = min(max(currentUnit(book: book), 0),
                              max(book.pages.count - 1, 0))
            return "第 \(clamped + 1) / \(book.pages.count) 页"
        }
    }

    // MARK: - 画笔工具栏

    @ViewBuilder
    private var penToolbar: some View {
        if brushBarCollapsed {
            collapsedBar
        } else {
            expandedBar
        }
    }

    private var collapsedBar: some View {
        Button {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                brushBarCollapsed = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 13))
                Text("画笔")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 18)
            .background(Color.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var expandedBar: some View {
        VStack(spacing: 8) {
            toolbarRow {
                ForEach(PenKind.allCases) { kind in
                    toolButton(isActive: activeTool == .brush(kind),
                               systemImage: kind.systemImage) {
                        if activeTool == .brush(kind) {
                            activePopover = (activePopover == .brush(kind))
                                ? nil : .brush(kind)
                        } else {
                            activeTool = .brush(kind)
                            activePopover = nil
                        }
                    }
                }

                rowDivider

                toolButton(isActive: activeTool.isEraser,
                           systemImage: eraserKind.systemImage) {
                    if activeTool.isEraser {
                        activePopover = (activePopover == .eraser) ? nil : .eraser
                    } else {
                        activeTool = .eraser
                        activePopover = nil
                    }
                }

                rowDivider

                toolButton(isActive: false,
                           systemImage: "arrow.uturn.backward") { undoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "arrow.uturn.forward") { redoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "trash") { clearTrigger += 1 }

                rowDivider

                toolButton(isActive: false,
                           systemImage: "square.3.layers.3d") { showLayers = true }

                rowDivider

                // 把照片导入到当前这一页（不新建）
                toolButton(isActive: false, systemImage: "photo.badge.plus") {
                    if let book {
                        chooseVisiblePage(book: book,
                                          title: "把照片导入到哪一页",
                                          isReplace: true)
                    }
                }

                rowDivider

                toolButton(isActive: false, systemImage: "chevron.down") {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        brushBarCollapsed = true
                    }
                }
            }

            toolbarRow {
                ForEach(PenColorPreset.allCases) { preset in
                    colorDot(preset.color, isSelected: penColor == preset.color) {
                        penColor = preset.color
                    }
                }

                rowDivider

                ForEach(settingsStore.savedColors) { item in
                    colorDot(item.color, isSelected: penColor == item.color) {
                        penColor = item.color
                    }
                    .onLongPressGesture {
                        settingsStore.removeColor(item)
                    }
                }

                ColorPicker("", selection: $penColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 26)

                Button {
                    settingsStore.addColor(penColor)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        saveColorPulse = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation { saveColorPulse = false }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(penColor)
                            .frame(width: 24, height: 24)
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(contrastingTextColor(for: penColor))
                    }
                    .scaleEffect(saveColorPulse ? 1.25 : 1.0)
                }
                .buttonStyle(.plain)

                rowDivider

                ForEach(quickWidths, id: \.self) { w in
                    Button {
                        var s = settingsStore.brushSettings(for: activeBrushKind)
                        s.width = w
                        settingsStore.updateBrush(s, for: activeBrushKind)
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: dotSize(for: w), height: dotSize(for: w))
                            .frame(width: 26, height: 26)
                            .background(abs(settingsStore.brushSettings(for: activeBrushKind).width - w) < 0.6
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var quickWidths: [Double] { [2, 5, 10, 18, 30] }

    private func dotSize(for width: Double) -> CGFloat {
        min(max(CGFloat(width) * 0.75, 4), 24)
    }

    private var rowDivider: some View {
        Divider()
            .frame(height: 20)
            .overlay(Color.white.opacity(0.25))
    }

    @ViewBuilder
    private func toolbarRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                content()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: 820)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    @ViewBuilder
    private func toolButton(isActive: Bool,
                            systemImage: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(isActive
                            ? Color.accentColor.opacity(0.36)
                            : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func colorDot(_ color: Color,
                          isSelected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(isSelected ? 0.95 : 0.16),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func contrastingTextColor(for color: Color) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .black }
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }

    // MARK: - 导航栏工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isPenActive.toggle()
                if !isPenActive { zoomResetTrigger += 1 }
            } label: {
                Image(systemName: isPenActive ? "pencil.circle.fill" : "pencil.circle")
                    .font(.title3)
            }

            Button { showThumbnails = true } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.title3)
            }

            Button { showOutline = true } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.title3)
            }

            Menu {
                Button {
                    toggleViewMode()
                } label: {
                    Label(viewMode == .spread ? "切换为单页" : "切换为双页",
                          systemImage: viewMode == .spread
                                        ? "rectangle.portrait" : "book")
                }

                Button {
                    showLayers = true
                } label: {
                    Label("图层", systemImage: "square.3.layers.3d")
                }

                Divider()

                Button {
                    if let book {
                        chooseVisiblePage(book: book,
                                          title: "把照片导入到哪一页",
                                          isReplace: true)
                    }
                } label: {
                    Label("导入照片到本页", systemImage: "photo.badge.plus")
                }

                Button {
                    if let book {
                        chooseVisiblePage(book: book,
                                          title: "调整哪一页的图片范围",
                                          isReplace: false)
                    }
                } label: {
                    Label("调整本页图片范围", systemImage: "crop")
                }

                Divider()

                Button {
                    appendPages([Page.blank()])
                } label: {
                    Label("末尾添加空白页", systemImage: "plus.rectangle")
                }

                Divider()

                Button {
                    importOccupiesSpread = false
                    replacePageIndex = nil
                    showPhotoPicker = true
                } label: {
                    Label("从照片导入（每张占一页）", systemImage: "photo")
                }
                Button {
                    importOccupiesSpread = false
                    showFileImporter = true
                } label: {
                    Label("从文件导入图片 / PDF", systemImage: "folder")
                }

                Divider()

                Button {
                    importOccupiesSpread = true
                    replacePageIndex = nil
                    showPhotoPicker = true
                } label: {
                    Label("从照片导入（占整个跨页）",
                          systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    importOccupiesSpread = true
                    showFileImporter = true
                } label: {
                    Label("从文件导入（占整个跨页）",
                          systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
    }

    // MARK: - 自动续页

    private func handleAutoAppend(book: Book, spreadIndex: Int, drawing: PKDrawing) {
        guard settings.autoAppendPage, !didAutoAppend else { return }
        guard !drawing.strokes.isEmpty else { return }

        let spreads = SpreadLayout.spreads(for: book)
        guard spreadIndex == spreads.count - 1 else { return }

        var updated = book
        updated.pages.append(.blank())
        library.update(updated)
        didAutoAppend = true
    }

    // MARK: - 导入

    /// 把选中的照片替换到指定页（不新建页）
    private func replacePhoto(_ items: [PhotosPickerItem], at index: Int) async {
        defer { photoItems = [] }

        guard let item = items.first,
              let data = try? await item.loadTransferable(type: Data.self) else {
            importMessage = "没能读取这张照片"
            return
        }

        let ext = ImageFileType.fileExtension(for: data)
        guard let name = try? FileStorage.saveImageData(data,
                                                        preferredExtension: ext) else {
            importMessage = "保存照片失败"
            return
        }

        replacePageImage(at: index, fileName: name)
    }

    private func replacePageImage(at index: Int, fileName: String) {
        guard var updated = library.book(id: bookID),
              updated.pages.indices.contains(index) else { return }

        let old = updated.pages[index].imageFileName

        updated.pages[index].kind = .image
        updated.pages[index].imageFileName = fileName
        updated.pages[index].transform = .identity

        library.update(updated)

        if let old { FileStorage.deleteImage(named: old) }
        Self.paperCache.removeAllObjects()
    }

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        var newPages: [Page] = []
        let occupies = importOccupiesSpread

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let ext = ImageFileType.fileExtension(for: data)
            if let name = try? FileStorage.saveImageData(data, preferredExtension: ext) {
                newPages.append(Page.image(fileName: name, occupiesSpread: occupies))
            }
        }

        photoItems = []

        guard !newPages.isEmpty else {
            importMessage = "没有导入任何图片"
            return
        }
        appendPages(newPages)
    }

    private func importFromFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importMessage = "导入失败：\(error.localizedDescription)"

        case .success(let urls):
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let occupies = importOccupiesSpread

            if ext == "pdf" {
                let dest = FileStorage.temporaryPDFURL()
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                } catch {
                    importMessage = "读取 PDF 失败：\(error.localizedDescription)"
                    return
                }
                Task { @MainActor in
                    await importPDFPages(url: dest, occupies: occupies)
                    FileStorage.deleteTemporaryPDF(url: dest)
                }
                return
            }

            guard let data = try? Data(contentsOf: url) else {
                importMessage = "读取文件失败"
                return
            }

            let fileExt = ext.isEmpty
                ? ImageFileType.fileExtension(for: data)
                : ext

            guard let name = try? FileStorage.saveImageData(data,
                                                            preferredExtension: fileExt) else {
                importMessage = "保存图片失败"
                return
            }

            appendPages([Page.image(fileName: name, occupiesSpread: occupies)])
        }
    }

    private func importPDFPages(url: URL, occupies: Bool) async {
        let total = PDFImporter.pageCount(url: url)
        guard total > 0 else {
            importMessage = "这个 PDF 没有可导入的页面"
            return
        }

        pdfImportTotal = total
        pdfImportDone = 0
        pdfImportProgress = 0

        var newPages: [Page] = []

        for i in 0..<total {
            let page: Page? = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    autoreleasepool {
                        guard let image = PDFImporter.renderPage(url: url,
                                                                 index: i,
                                                                 maxPixel: 2400),
                              let data = image.jpegData(compressionQuality: 0.9),
                              let name = try? FileStorage.saveImageData(
                                  data,
                                  preferredExtension: "jpg"
                              ) else {
                            cont.resume(returning: nil)
                            return
                        }
                        cont.resume(returning: Page.image(fileName: name,
                                                         occupiesSpread: occupies))
                    }
                }
            }

            if let page { newPages.append(page) }

            pdfImportDone = i + 1
            pdfImportProgress = Double(i + 1) / Double(total)
        }

        pdfImportProgress = nil

        if newPages.isEmpty {
            importMessage = "PDF 渲染失败"
            return
        }

        appendPages(newPages)
    }

    private func appendPages(_ newPages: [Page]) {
        guard var currentBook = book else { return }
        let startIndex = currentBook.pages.count
        currentBook.pages.append(contentsOf: newPages)
        library.update(currentBook)

        didAutoAppend = false
        isDraggingPage = false
        Self.paperCache.removeAllObjects()

        if viewMode == .spread {
            position = Double(SpreadLayout.spreadIndex(containingPage: startIndex,
                                                       in: currentBook))
        } else {
            position = Double(startIndex)
        }
    }
}

// MARK: - 笔刷设置面板

struct BrushSettingsPanel: View {
    @ObservedObject var settingsStore: AppSettingsStore
    let kind: PenKind
    let color: Color
    let onClose: () -> Void

    var body: some View {
        let s = settingsStore.brushSettings(for: kind)

        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(kind.displayName)设置")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("粗细")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f", s.width))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: widthBinding, in: 1...60)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("不透明度")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(s.opacity * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: opacityBinding, in: 0.05...1.0)
            }

            HStack(spacing: 12) {
                Circle()
                    .fill(color.opacity(s.clampedOpacity))
                    .frame(width: min(max(s.clampedWidth, 6), 34),
                           height: min(max(s.clampedWidth, 6), 34))
                    .frame(width: 40, height: 40)

                Text(kind == .marker
                     ? "荧光笔建议 30%~45% 不透明度"
                     : "拖动滑杆即时生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                settingsStore.resetBrush(kind)
            } label: {
                Label("恢复默认", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var widthBinding: Binding<Double> {
        Binding(
            get: { settingsStore.brushSettings(for: kind).width },
            set: { value in
                var s = settingsStore.brushSettings(for: kind)
                s.width = value
                settingsStore.updateBrush(s, for: kind)
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { settingsStore.brushSettings(for: kind).opacity },
            set: { value in
                var s = settingsStore.brushSettings(for: kind)
                s.opacity = value
                settingsStore.updateBrush(s, for: kind)
            }
        )
    }
}

// MARK: - 橡皮面板

struct EraserPanel: View {
    @Binding var kind: EraserKind
    @Binding var width: EraserWidth
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("橡皮")
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 10) {
                ForEach(EraserKind.allCases) { k in
                    Button {
                        kind = k
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: k.systemImage)
                                .font(.system(size: 18))
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(k.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(k.descriptionText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if kind == k {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(kind == k
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(kind == k
                                        ? Color.accentColor.opacity(0.5)
                                        : Color.secondary.opacity(0.18),
                                        lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("橡皮大小")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    ForEach(EraserWidth.allCases) { w in
                        Button {
                            width = w
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(Color.primary.opacity(0.85))
                                    .frame(width: w.dotSize, height: w.dotSize)
                                    .frame(width: 44, height: 44)
                                    .background(width == w
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                Text(w.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(kind == .vector
                 ? "矢量橡皮会整笔删除，大小设置不影响它。"
                 : "精确橡皮只擦掉笔尖经过的位置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 330)
    }
}
