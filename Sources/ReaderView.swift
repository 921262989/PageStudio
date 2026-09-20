import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import PencilKit

struct BookReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @StateObject private var layerStore = LayerStore()

    let bookID: UUID

    // MARK: 阅读位置（连续值，跟手翻页核心）
    @State private var position: Double = 0
    @State private var viewMode: ViewMode = .spread
    @State private var didInitialize = false

    // MARK: 拖拽
    @State private var isDraggingPage = false
    @State private var dragStartPosition: Double = 0

    // MARK: 绘制
    @State private var isPenActive = false
    @State private var activeTool: ActiveTool = .brush(.pen)
    @State private var penColor: Color = Color(white: 0.06)
    @State private var draftColor: Color = Color(red: 0.1, green: 0.5, blue: 0.9)
    @State private var eraserKind: EraserKind = .precise
    @State private var eraserWidth: EraserWidth = .medium

    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0
    @State private var zoomResetTrigger = 0
    @State private var zoomInTrigger = 0
    @State private var zoomOutTrigger = 0
    @State private var zoomLevel: CGFloat = 1

    @State private var showBrushSettings = false
    @State private var brushBarCollapsed = false
    @State private var saveColorPulse = false

    // MARK: 图层
    @State private var activeLayerIDs: [String: UUID] = [:]

    // MARK: 面板
    @State private var showThumbnails = false
    @State private var showOutline = false
    @State private var showLayers = false
    @State private var showImageAdjust = false

    @State private var didAutoAppend = false

    // MARK: 导入
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importOccupiesSpread = false
    @State private var importMessage: String? = nil

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
            Task { await importFromPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
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
            if let book, let pageIndex = currentPageIndexForAdjust(book: book) {
                ImageAdjustView(page: book.pages[pageIndex],
                                book: book) { newTransform in
                    guard var updated = library.book(id: bookID),
                          updated.pages.indices.contains(pageIndex) else { return }
                    updated.pages[pageIndex].transform = newTransform
                    library.update(updated)
                }
            }
        }
        .onChange(of: library.book(id: bookID)?.pages.count ?? 0) { _ in
            clampPosition()
        }
        .onChange(of: isPenActive) { active in
            if active {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    brushBarCollapsed = false
                }
            } else {
                layerStore.objectWillChange.send()
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

    // MARK: - 主布局

    @ViewBuilder
    private func main(book: Book, container: CGSize) -> some View {
        VStack(spacing: 0) {
            GeometryReader { inner in
                bookArea(book: book, available: inner.size)
            }

            if !isPenActive && !book.pages.isEmpty {
                bottomBar(book: book)
            }
        }
        .frame(width: container.width, height: container.height)
        .overlay(alignment: .bottom) {
            if isPenActive {
                penToolbar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
            }
        }
        .popover(isPresented: $showBrushSettings, arrowEdge: .bottom) {
            BrushSettingsPanel(settingsStore: settingsStore,
                               kind: activeBrushKind,
                               color: penColor,
                               onClose: { showBrushSettings = false })
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
        let frac = clamped - Double(from)

        ZStack {
            if book.pages.isEmpty {
                emptyHint
            } else if frac > 0.002, from + 1 < count {
                spreadOrSingleFlipping(book: book,
                                       size: size,
                                       from: from,
                                       progress: CGFloat(frac))
            } else {
                stableScene(book: book, size: size, index: from)
            }
        }
        .frame(width: available.width, height: available.height)
        .contentShape(Rectangle())
        .gesture(turnGesture(size: size, book: book))
        .simultaneousGesture(edgeTapGesture(available: available, book: book))
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("这本画册还没有页面")
                .foregroundStyle(.secondary)
            Text("点右上角 ⋯ 导入图片")
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

            ForEach(layers) { meta in
                if editingThisUnit && meta.id == activeID {
                    drawingCanvas(book: book, unitIndex: index, size: size,
                                  spreadIndex: sIndex, layerID: meta.id)
                } else if meta.isVisible {
                    InkImageView(drawing: layerStore.drawing(bookId: book.id,
                                                             spreadIndex: sIndex,
                                                             layerID: meta.id),
                                 size: spreadSize,
                                 revision: layerStore.version,
                                 opacity: meta.opacity)
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

    // MARK: - 翻页场景

    @ViewBuilder
    private func spreadOrSingleFlipping(book: Book, size: ReaderSize,
                                        from: Int, progress: CGFloat) -> some View {
        if viewMode == .spread {
            spreadFlippingScene(book: book, size: size, from: from, progress: progress)
        } else {
            singleFlippingScene(book: book, size: size, from: from, progress: progress)
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
                SpreadCanvasView(book: book,
                                 spread: toSpread,
                                 pageWidth: pw,
                                 pageHeight: ph,
                                 drawingRevision: layerStore.version,
                                 showDrawing: false,
                                 theme: theme)
                    .frame(width: pw * 2, height: ph)
                    .overlay {
                        bakedLayers(book: book,
                                    spreadIndex: to,
                                    size: CGSize(width: pw * 2, height: ph))
                    }

                pageOrPaper(book: book, index: fromSides.left, size: size)
                    .position(x: pw / 2, y: ph / 2)

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
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                        style: .continuous))
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
                SinglePageView(book: book,
                               pageIndex: to,
                               pageWidth: pw,
                               pageHeight: ph,
                               drawingRevision: layerStore.version,
                               showDrawing: false,
                               theme: theme)
                    .overlay {
                        bakedLayers(book: book,
                                    spreadIndex: SpreadLayout.spreadIndex(
                                        containingPage: to, in: book),
                                    size: CGSize(width: pw * 2, height: ph))
                            .frame(width: pw, height: ph)
                            .clipped()
                    }

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
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                        style: .continuous))
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
                    bakedLayers(book: book,
                                spreadIndex: SpreadLayout.spreadIndex(
                                    containingPage: index, in: book),
                                size: CGSize(width: size.pageWidth * 2,
                                             height: size.pageHeight))
                        .frame(width: size.pageWidth, height: size.pageHeight)
                        .clipped()
                }
        } else {
            PaperView(theme: theme)
                .frame(width: size.pageWidth, height: size.pageHeight)
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

    // MARK: - 绘制画布

    @ViewBuilder
    private func drawingCanvas(book: Book, unitIndex index: Int,
                               size: ReaderSize, spreadIndex: Int,
                               layerID: UUID) -> some View {
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)

        // 视口：双页模式 = 整个跨页；单页模式 = 半个跨页
        let isSingle = (viewMode == .single)
        let viewport = isSingle
            ? CGSize(width: logical.width / 2, height: logical.height)
            : logical

        let showRightHalf = isSingle && isRightPage(unitIndex: index, book: book)
        let initialOffsetX: CGFloat = showRightHalf ? logical.width / 2 : 0

        let displayViewportWidth = size.containerWidth
        let scale = displayViewportWidth / max(viewport.width, 1)

        DrawingCanvas(
            canvasSize: logical,
            viewportSize: viewport,
            initialOffsetX: initialOffsetX,
            displaySize: CGSize(width: size.pageWidth * 2,
                                height: size.pageHeight),
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
                penColor = picked
                draftColor = picked
                if activeTool.isEraser {
                    activeTool = .brush(.pen)
                }
            },
            onZoomChanged: { level in
                zoomLevel = level
            }
        )
        .frame(width: viewport.width, height: viewport.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.containerWidth, height: size.containerHeight,
               alignment: .topLeading)
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
            let ui = UIColor(penColor).withAlphaComponent(s.clampedOpacity)
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
        !(isPenActive && !settings.pencilOnlyDrawMode)
    }

    private var edgeTapActive: Bool {
        settings.edgeTapTurn && (!isPenActive || settings.pencilOnlyDrawMode)
    }

    /// 跟手翻页：手指移多少，页面转多少；手指停，页面停。
    private func turnGesture(size: ReaderSize, book: Book) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard pagingEnabled else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.1 else { return }

                if !isDraggingPage {
                    isDraggingPage = true
                    dragStartPosition = position
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                let pageW = max(size.containerWidth, 80)
                let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1
                let delta = Double(dx / pageW) * direction

                let count = readerUnitCount(book: book)
                let maxPos = Double(max(count - 1, 0))

                position = min(max(dragStartPosition + delta, 0), maxPos)
            }
            .onEnded { value in
                guard isDraggingPage else { return }
                isDraggingPage = false

                let count = readerUnitCount(book: book)
                let maxPos = Double(max(count - 1, 0))
                let pageW = max(size.containerWidth, 80)
                let direction: Double = (book.bindingDirection == .leftToRight) ? -1 : 1

                let predictedDelta = Double(value.predictedEndTranslation.width / pageW)
                    * direction
                let predicted = dragStartPosition + predictedDelta
                let target = min(max(predicted.rounded(), 0), maxPos)

                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    position = target
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }

    private func edgeTapGesture(available: CGSize, book: Book) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard edgeTapActive else { return }
                let w = available.width
                let x = value.location.x

                if x < w * 0.16 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        position = max(position - 1, 0)
                    }
                } else if x > w * 0.84 {
                    let maxPos = Double(max(readerUnitCount(book: book) - 1, 0))
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        position = min(position + 1, maxPos)
                    }
                }
            }
    }

    // MARK: - 位置

    private func clampPosition() {
        guard let book else { return }
        let maxPos = Double(max(readerUnitCount(book: book) - 1, 0))
        position = min(max(position, 0), maxPos)
        isDraggingPage = false
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

    private func currentPageIndexForAdjust(book: Book) -> Int? {
        guard !book.pages.isEmpty else { return nil }
        return currentPageIndex(book: book)
    }

    private func jump(toPage pageIdx: Int, book: Book) {
        isDraggingPage = false
        if viewMode == .spread {
            position = Double(SpreadLayout.spreadIndex(containingPage: pageIdx,
                                                       in: book))
        } else {
            position = Double(pageIdx)
        }
    }

    // MARK: - 底部栏

    @ViewBuilder
    private func bottomBar(book: Book) -> some View {
        let count = readerUnitCount(book: book)
        let current = currentUnit(book: book)

        HStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    position = max(position - 1, 0)
                }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .disabled(current <= 0)

            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
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
        .padding(.bottom, 10)
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
                        activeTool = .brush(kind)
                    }
                }

                rowDivider

                eraserMenu

                rowDivider

                toolButton(isActive: false,
                           systemImage: "arrow.uturn.backward") { undoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "arrow.uturn.forward") { redoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "trash") { clearTrigger += 1 }

                rowDivider

                toolButton(isActive: false,
                           systemImage: "square.3.layers.3d") {
                    showLayers = true
                }

                rowDivider

                // 精确缩放
                toolButton(isActive: false, systemImage: "minus.magnifyingglass") {
                    zoomOutTrigger += 1
                }
                Button {
                    zoomResetTrigger += 1
                } label: {
                    Text("\(Int((zoomLevel * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 52)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                toolButton(isActive: false, systemImage: "plus.magnifyingglass") {
                    zoomInTrigger += 1
                }

                rowDivider

                toolButton(isActive: false,
                           systemImage: "chevron.down") {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        brushBarCollapsed = true
                    }
                }
            }

            toolbarRow {
                ForEach(PenColorPreset.allCases) { preset in
                    colorDot(preset.color, isSelected: penColor == preset.color) {
                        penColor = preset.color
                        draftColor = preset.color
                    }
                }

                rowDivider

                ForEach(settingsStore.savedColors) { item in
                    colorDot(item.color, isSelected: penColor == item.color) {
                        penColor = item.color
                        draftColor = item.color
                    }
                    .onLongPressGesture {
                        settingsStore.removeColor(item)
                    }
                }

                ColorPicker("", selection: $draftColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 26)
                    .onChange(of: draftColor) { newValue in
                        penColor = newValue
                    }

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

                Button {
                    showBrushSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                        Text("\(Int(settingsStore.brushSettings(for: activeBrushKind).width))")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text("·")
                            .foregroundStyle(.white.opacity(0.4))
                        Text("\(Int(settingsStore.brushSettings(for: activeBrushKind).opacity * 100))%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var eraserMenu: some View {
        Menu {
            Section("橡皮类型") {
                ForEach(EraserKind.allCases) { k in
                    Button {
                        eraserKind = k
                        activeTool = .eraser
                    } label: {
                        Label(k.displayName,
                              systemImage: eraserKind == k ? "checkmark"
                                                           : k.systemImage)
                    }
                }
            }
            Section("橡皮大小") {
                ForEach(EraserWidth.allCases) { w in
                    Button {
                        eraserWidth = w
                        activeTool = .eraser
                    } label: {
                        Label(w.displayName,
                              systemImage: eraserWidth == w ? "checkmark" : "circle")
                    }
                }
            }
        } label: {
            Image(systemName: eraserKind.systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(activeTool.isEraser
                            ? Color.accentColor.opacity(0.36)
                            : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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

                Button {
                    showImageAdjust = true
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
                    showPhotoPicker = true
                } label: {
                    Label("从照片导入（每张占一页）", systemImage: "photo")
                }
                Button {
                    importOccupiesSpread = false
                    showFileImporter = true
                } label: {
                    Label("从文件导入（每张占一页）", systemImage: "folder")
                }

                Divider()

                Button {
                    importOccupiesSpread = true
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
            var newPages: [Page] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension.isEmpty
                    ? ImageFileType.fileExtension(for: data)
                    : url.pathExtension.lowercased()

                if let name = try? FileStorage.saveImageData(data,
                                                             preferredExtension: ext) {
                    newPages.append(Page.image(fileName: name,
                                               occupiesSpread: importOccupiesSpread))
                }
            }

            if newPages.isEmpty {
                importMessage = "没有导入任何图片"
            } else {
                appendPages(newPages)
            }
        }
    }

    private func appendPages(_ newPages: [Page]) {
        guard var currentBook = book else { return }
        let startIndex = currentBook.pages.count
        currentBook.pages.append(contentsOf: newPages)
        library.update(currentBook)

        didAutoAppend = false
        isDraggingPage = false

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
