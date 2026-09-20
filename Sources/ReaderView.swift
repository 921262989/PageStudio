import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import PencilKit

struct BookReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore
    @StateObject private var drawingStore = DrawingStore()

    let bookID: UUID

    // 阅读位置
    @State private var viewMode: ViewMode = .spread
    @State private var unitIndex = 0
    @State private var didInitialize = false

    // 绘制
    @State private var isPenActive = false
    @State private var activeTool: ActiveTool = .brush(.pen)
    @State private var penColor: Color = Color(white: 0.05)
    @State private var customColor: Color = Color(red: 0.1, green: 0.5, blue: 0.9)
    @State private var penWidth: PenWidth = .medium
    @State private var eraserKind: EraserKind = .precise
    @State private var eraserWidth: EraserWidth = .medium

    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0
    @State private var zoomResetTrigger = 0
    @State private var showEraserPanel = false

    /// 每一页翻页动画时长
    private let flipStepDuration: Double = 0.20
    /// 每滑动这么多点，翻一页
    private let swipeStepPoints: CGFloat = 90
    /// 一次滑动最多翻多少页
    private let maxFlipPerSwipe = 25

    // 翻页状态
    @State private var flipProgress: CGFloat = 0
    @State private var isFlipping = false
    @State private var flipForward = true
    @State private var flipFromIndex = 0
    @State private var pendingFlips = 0
    @State private var flipLoopRunning = false
    @State private var dragStepsApplied = 0

    @State private var didAutoAppend = false

    // 面板
    @State private var showThumbnails = false
    @State private var showOutline = false

    // 导入
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
                                       clampAfterEdit()
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
        .onChange(of: library.book(id: bookID)?.pages.count ?? 0) { _ in
            clampAfterEdit()
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
        .popover(isPresented: $showEraserPanel, arrowEdge: .bottom) {
            EraserPanel(kind: $eraserKind,
                        width: $eraserWidth,
                        onClose: { showEraserPanel = false })
        }
    }

    // MARK: - 书籍区域

    @ViewBuilder
    private func bookArea(book: Book, available: CGSize) -> some View {
        let size = readerSize(in: available, book: book)
        let count = readerUnitCount(book: book)
        let clamped = min(max(unitIndex, 0), max(count - 1, 0))

        ZStack {
            if book.pages.isEmpty {
                emptyHint
            } else if isFlipping {
                flippingScene(book: book, size: size,
                              from: flipFromIndex,
                              forward: flipForward)
            } else {
                stableScene(book: book, size: size, index: clamped)
            }
        }
        .frame(width: available.width, height: available.height)
        .contentShape(Rectangle())
        .gesture(turnGesture(available: available))
        .simultaneousGesture(edgeTapGesture(available: available))
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
        // ⚠️ 编辑中的那一页不显示烘焙笔迹，否则会和画布上的实时笔迹重叠，
        //    表现为「颜色变深、笔画变粗、几秒后变样」
        let showBakedInk = !(isPenActive && index == unitIndex)

        Group {
            if viewMode == .spread {
                let spreads = SpreadLayout.spreads(for: book)
                if spreads.indices.contains(index) {
                    SpreadCanvasView(book: book,
                                     spread: spreads[index],
                                     pageWidth: size.pageWidth,
                                     pageHeight: size.pageHeight,
                                     drawingRevision: drawingStore.revision,
                                     showDrawing: showBakedInk,
                                     theme: theme)
                } else {
                    PaperView(theme: theme)
                }
            } else {
                SinglePageView(book: book,
                               pageIndex: index,
                               pageWidth: size.pageWidth,
                               pageHeight: size.pageHeight,
                               drawingRevision: drawingStore.revision,
                               showDrawing: showBakedInk,
                               theme: theme)
            }
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
        .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous)
                .stroke(theme.paperBorderColor, lineWidth: 0.5)
        )
        .overlay {
            if isPenActive && index == unitIndex {
                drawingLayer(book: book, unitIndex: index, size: size)
            }
        }
    }

    // MARK: - 翻页场景

    @ViewBuilder
    private func flippingScene(book: Book, size: ReaderSize,
                               from: Int, forward: Bool) -> some View {
        if viewMode == .spread {
            spreadFlippingScene(book: book, size: size, from: from, forward: forward)
        } else {
            singleFlippingScene(book: book, size: size, from: from, forward: forward)
        }
    }

    @ViewBuilder
    private func spreadFlippingScene(book: Book, size: ReaderSize,
                                     from: Int, forward: Bool) -> some View {
        let spreads = SpreadLayout.spreads(for: book)
        let pw = size.pageWidth
        let ph = size.pageHeight
        let to = forward ? from + 1 : from - 1

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
                                 drawingRevision: drawingStore.revision,
                                 showDrawing: true,
                                 theme: theme)
                    .frame(width: pw * 2, height: ph)

                if forward {
                    pageOrPaper(book: book, index: fromSides.left, size: size)
                        .position(x: pw / 2, y: ph / 2)
                } else {
                    pageOrPaper(book: book, index: fromSides.right, size: size)
                        .position(x: pw * 1.5, y: ph / 2)
                }

                if forward {
                    FlipCard(front: pageOrPaper(book: book, index: fromSides.right,
                                                size: size),
                             back: pageOrPaper(book: book, index: toSides.left,
                                               size: size),
                             angle: -Double(flipProgress) * 180,
                             anchor: .leading,
                             perspective: 0.32,
                             dimming: theme.flipDimming,
                             paperColor: theme.paperColor,
                             borderColor: theme.paperBorderColor)
                        .frame(width: pw, height: ph)
                        .position(x: pw * 1.5, y: ph / 2)
                } else {
                    FlipCard(front: pageOrPaper(book: book, index: fromSides.left,
                                                size: size),
                             back: pageOrPaper(book: book, index: toSides.right,
                                               size: size),
                             angle: Double(flipProgress) * 180,
                             anchor: .trailing,
                             perspective: 0.32,
                             dimming: theme.flipDimming,
                             paperColor: theme.paperColor,
                             borderColor: theme.paperBorderColor)
                        .frame(width: pw, height: ph)
                        .position(x: pw / 2, y: ph / 2)
                }
            }
            .frame(width: pw * 2, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                        style: .continuous))
        }
    }

    @ViewBuilder
    private func singleFlippingScene(book: Book, size: ReaderSize,
                                     from: Int, forward: Bool) -> some View {
        let pw = size.pageWidth
        let ph = size.pageHeight
        let to = forward ? from + 1 : from - 1

        if book.pages.indices.contains(from), book.pages.indices.contains(to) {
            ZStack {
                SinglePageView(book: book,
                               pageIndex: to,
                               pageWidth: pw,
                               pageHeight: ph,
                               drawingRevision: drawingStore.revision,
                               showDrawing: true,
                               theme: theme)

                FlipCard(front: pageOrPaper(book: book, index: from, size: size),
                         back: pageOrPaper(book: book, index: to, size: size),
                         angle: forward ? -Double(flipProgress) * 180
                                        :  Double(flipProgress) * 180,
                         anchor: forward ? .leading : .trailing,
                         perspective: 0.32,
                         dimming: theme.flipDimming,
                         paperColor: theme.paperColor,
                         borderColor: theme.paperBorderColor)
                    .frame(width: pw, height: ph)
            }
            .frame(width: pw, height: ph)
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius,
                                        style: .continuous))
        }
    }

    @ViewBuilder
    private func pageOrPaper(book: Book, index: Int?, size: ReaderSize) -> some View {
        if let index, book.pages.indices.contains(index) {
            SinglePageView(book: book,
                           pageIndex: index,
                           pageWidth: size.pageWidth,
                           pageHeight: size.pageHeight,
                           drawingRevision: drawingStore.revision,
                           showDrawing: true,
                           theme: theme)
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

    // MARK: - 绘制层

    @ViewBuilder
    private func drawingLayer(book: Book, unitIndex index: Int, size: ReaderSize) -> some View {
        let sIndex = spreadIndexForUnit(index, book: book)
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
        let displayWidth = size.pageWidth * 2
        let scale = displayWidth / logical.width
        let showRightHalf = viewMode == .single && isRightPage(unitIndex: index, book: book)

        let canvas = DrawingCanvas(
            canvasSize: logical,
            initialDrawing: drawingStore.load(bookId: book.id, spreadIndex: sIndex),
            pencilOnly: settings.pencilOnlyDrawMode,
            tool: currentTool,
            toolSignature: toolSignature,
            undoTrigger: undoTrigger,
            redoTrigger: redoTrigger,
            clearTrigger: clearTrigger,
            zoomResetTrigger: zoomResetTrigger,
            onDrawingChanged: { newDrawing in
                drawingStore.save(newDrawing, bookId: book.id, spreadIndex: sIndex)
                handleAutoAppend(book: book, spreadIndex: sIndex, drawing: newDrawing)
            },
            onDrawingStateChanged: { _ in }
        )
        .frame(width: logical.width, height: logical.height)
        .scaleEffect(scale, anchor: .topLeading)

        Color.clear
            .frame(width: size.containerWidth, height: size.containerHeight)
            .overlay(alignment: .topLeading) {
                canvas.offset(x: showRightHalf ? -size.pageWidth : 0)
            }
            .clipped()
    }

    // MARK: - 工具构造

    private var currentTool: PKTool {
        switch activeTool {
        case .brush(let kind):
            let ui = UIColor(penColor).withAlphaComponent(kind.alpha)
            let width = penWidth.value * kind.widthMultiplier
            return PKInkingTool(kind.inkType, color: ui, width: width)

        case .eraser:
            // ⚠️ 带宽度的构造函数是 iOS 16.4 才有的。
            //    低版本退回系统默认大小，不会崩。
            if #available(iOS 16.4, *) {
                return PKEraserTool(eraserKind.pkType, width: eraserWidth.value)
            } else {
                return PKEraserTool(eraserKind.pkType)
            }
        }
    }

    /// ⚠️ 必须是稳定字符串。签名一变画布就会重设工具，
    ///    在落笔过程中重设会打断笔迹渲染。
    private var toolSignature: String {
        switch activeTool {
        case .brush(let kind):
            return "brush|\(kind.rawValue)|\(stableColorKey(penColor))|\(penWidth.rawValue)"
        case .eraser:
            return "eraser|\(eraserKind.rawValue)|\(eraserWidth.rawValue)"
        }
    }

    private func spreadIndexForUnit(_ index: Int, book: Book) -> Int {
        if viewMode == .spread {
            return index
        } else {
            return SpreadLayout.spreadIndex(containingPage: index, in: book)
        }
    }

    private func isRightPage(unitIndex index: Int, book: Book) -> Bool {
        guard let s = SpreadLayout.spread(containingPage: index, in: book) else {
            return false
        }
        return SpreadLayout.visualSides(of: s, binding: book.bindingDirection).right == index
    }

    // MARK: - 手势

    private var pagingEnabled: Bool {
        !(isPenActive && !settings.pencilOnlyDrawMode)
    }

    private var edgeTapActive: Bool {
        settings.edgeTapTurn && (!isPenActive || settings.pencilOnlyDrawMode)
    }

    /// 滑动 = 连续翻多页
    private func turnGesture(available: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard pagingEnabled, let book else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.2 else { return }

                let forward = shouldTurnForward(dx: dx)
                let steps = Int(abs(dx) / swipeStepPoints)

                if steps > dragStepsApplied {
                    let extra = steps - dragStepsApplied
                    dragStepsApplied = steps
                    flipForward = forward
                    pendingFlips += extra
                    if !flipLoopRunning {
                        stepFlip(book: book)
                    }
                    playHaptic()
                }
            }
            .onEnded { value in
                guard let book else {
                    resetFlip()
                    return
                }

                let predicted = abs(value.predictedEndTranslation.width)
                let predictedSteps = Int(predicted / swipeStepPoints)
                let extra = max(0, predictedSteps - dragStepsApplied)

                if extra > 0 {
                    let capped = min(extra, maxFlipPerSwipe)
                    let forward = shouldTurnForward(
                        dx: value.translation.width != 0
                            ? value.translation.width
                            : value.predictedEndTranslation.width
                    )
                    flipForward = forward
                    pendingFlips += capped
                    if !flipLoopRunning {
                        stepFlip(book: book)
                    }
                } else if dragStepsApplied == 0 && pendingFlips == 0 {
                    flipForward = shouldTurnForward(dx: value.translation.width)
                    pendingFlips = 1
                    stepFlip(book: book)
                }

                dragStepsApplied = 0
            }
    }

    private func shouldTurnForward(dx: CGFloat) -> Bool {
        let direction = book?.bindingDirection ?? .leftToRight
        return direction == .leftToRight ? (dx < 0) : (dx > 0)
    }

    /// 点边缘翻页：用坐标判断，不占位、不吃手势
    private func edgeTapGesture(available: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard edgeTapActive else { return }
                let w = available.width
                let x = value.location.x
                if x < w * 0.16 {
                    requestSingleFlip(forward: false)
                } else if x > w * 0.84 {
                    requestSingleFlip(forward: true)
                }
            }
    }

    // MARK: - 翻页执行

    private func requestSingleFlip(forward: Bool) {
        guard let book else { return }
        guard !flipLoopRunning else { return }
        flipForward = forward
        pendingFlips = 1
        stepFlip(book: book)
    }

    /// 消费翻页队列：一次翻一页，用短动画连播
    private func stepFlip(book: Book) {
        let total = readerUnitCount(book: book)
        let next = flipForward ? unitIndex + 1 : unitIndex - 1

        guard pendingFlips > 0, next >= 0, next < total else {
            pendingFlips = 0
            flipLoopRunning = false
            isFlipping = false
            flipProgress = 0
            return
        }

        pendingFlips -= 1
        flipLoopRunning = true
        flipFromIndex = unitIndex
        isFlipping = true
        flipProgress = 0

        withAnimation(.easeInOut(duration: flipStepDuration)) {
            flipProgress = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + flipStepDuration) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                unitIndex = next
                flipProgress = 0
            }
            stepFlip(book: book)
        }
    }

    private func resetFlip() {
        pendingFlips = 0
        flipLoopRunning = false
        dragStepsApplied = 0
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            flipProgress = 0
            isFlipping = false
        }
    }

    private func playHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - 导航

    private func goForward() { requestSingleFlip(forward: true) }
    private func goBackward() { requestSingleFlip(forward: false) }

    private func clampAfterEdit() {
        guard let book else { return }
        unitIndex = min(max(unitIndex, 0), max(readerUnitCount(book: book) - 1, 0))
        resetFlip()
    }

    private func initialize(container: CGSize) {
        guard !didInitialize, let book else { return }
        didInitialize = true
        let isPortrait = container.height > container.width
        viewMode = isPortrait ? .single : book.defaultViewMode
        unitIndex = 0
    }

    private func toggleViewMode() {
        guard let book else { return }
        resetFlip()
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let clamped = min(max(unitIndex, 0), max(spreads.count - 1, 0))
            if let firstPage = spreads[clamped].pageIndices.first {
                unitIndex = firstPage
            }
            viewMode = .single
        } else {
            unitIndex = SpreadLayout.spreadIndex(containingPage: unitIndex, in: book)
            viewMode = .spread
        }
    }

    private func currentPageIndex(book: Book) -> Int {
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let clamped = min(max(unitIndex, 0), max(spreads.count - 1, 0))
            return spreads[clamped].pageIndices.first ?? 0
        } else {
            return min(max(unitIndex, 0), max(book.pages.count - 1, 0))
        }
    }

    private func jump(toPage pageIdx: Int, book: Book) {
        resetFlip()
        if viewMode == .spread {
            unitIndex = SpreadLayout.spreadIndex(containingPage: pageIdx, in: book)
        } else {
            unitIndex = pageIdx
        }
    }

    // MARK: - 底部栏

    @ViewBuilder
    private func bottomBar(book: Book) -> some View {
        let count = readerUnitCount(book: book)

        HStack(spacing: 14) {
            Button { goBackward() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .disabled(unitIndex <= 0 || flipLoopRunning)

            Button { goForward() } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .disabled(unitIndex >= count - 1 || flipLoopRunning)

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
            let clamped = min(max(unitIndex, 0), max(count - 1, 0))
            let start = clamped * 2 + 1
            let end = min(start + 1, book.pages.count)
            return "跨页 \(start)-\(end)"
        } else {
            let clamped = min(max(unitIndex, 0), max(book.pages.count - 1, 0))
            return "第 \(clamped + 1) / \(book.pages.count) 页"
        }
    }

    // MARK: - 笔工具栏

    private var penToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PenKind.allCases) { kind in
                    toolButton(isActive: activeTool == .brush(kind),
                               systemImage: kind.systemImage) {
                        activeTool = .brush(kind)
                    }
                }

                Divider().frame(height: 20)

                toolButton(isActive: activeTool.isEraser,
                           systemImage: eraserKind.systemImage) {
                    activeTool = .eraser
                    showEraserPanel = true
                }

                Divider().frame(height: 20)

                ForEach(PenColorPreset.allCases) { preset in
                    Circle()
                        .fill(preset.color)
                        .frame(width: 19, height: 19)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(penColor == preset.color
                                                    ? 0.95 : 0.16),
                                lineWidth: penColor == preset.color ? 2.5 : 1
                            )
                        )
                        .onTapGesture { penColor = preset.color }
                }

                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 26)
                    .onChange(of: customColor) { newValue in
                        penColor = newValue
                    }

                Divider().frame(height: 20)

                ForEach(PenWidth.allCases) { w in
                    Button {
                        penWidth = w
                    } label: {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: w.dotSize, height: w.dotSize)
                            .frame(width: 26, height: 26)
                            .background(penWidth == w
                                        ? Color.accentColor.opacity(0.25)
                                        : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 20)

                toolButton(isActive: false,
                           systemImage: "arrow.uturn.backward") { undoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "arrow.uturn.forward") { redoTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "trash") { clearTrigger += 1 }
                toolButton(isActive: false,
                           systemImage: "arrow.up.left.and.arrow.down.right") {
                    zoomResetTrigger += 1
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: 760)
        .background(Color.black.opacity(0.70), in: Capsule())
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

    // MARK: - 导航栏工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isPenActive.toggle()
                if isPenActive { resetFlip() }
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
        resetFlip()

        if viewMode == .spread {
            unitIndex = SpreadLayout.spreadIndex(containingPage: startIndex,
                                                 in: currentBook)
        } else {
            unitIndex = startIndex
        }
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
