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

    // MARK: 阅读位置
    @State private var viewMode: ViewMode = .spread
    @State private var unitIndex = 0
    @State private var didInitialize = false

    // MARK: 绘制
    @State private var isPenActive = false
    @State private var penKind: PenKind = .pen
    @State private var penColorEnum: PenColor = .black
    @State private var penWidth: PenWidth = .medium
    @State private var isDrawingNow = false
    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0
    @State private var didAutoAppend = false

    // MARK: 硬纸板翻页
    @State private var flipProgress: CGFloat = 0
    @State private var isFlipping = false
    @State private var flipForward = true
    @State private var flipFromIndex = 0

    // MARK: 面板
    @State private var scrubbing: Int? = nil
    @State private var showThumbnails = false
    @State private var showOutline = false

    // MARK: 导入
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importOccupiesSpread = false
    @State private var importMessage: String? = nil

    private let flipDuration: Double = 0.50
    /// 拖拽超过这个比例就判定为"翻过去"
    private let commitThreshold: CGFloat = 0.36

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
            .onChange(of: settingsStore.settings.readerTheme) { _ in
                // 主题切换：不重置阅读位置，只重绘
            }
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
                                   theme: theme) { pageIdx in
                    jump(toPage: pageIdx, book: book)
                }
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
            clampPosition()
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
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            }
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
        .overlay { scrubPreview(book: book, size: size) }
        .overlay(alignment: .topLeading) { edgeTapZone(alignment: .leading, book: book) }
        .overlay(alignment: .topTrailing) { edgeTapZone(alignment: .trailing, book: book) }
        .contentShape(Rectangle())
        .gesture(turnGesture)
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
        Group {
            if viewMode == .spread {
                let spreads = SpreadLayout.spreads(for: book)
                if spreads.indices.contains(index) {
                    SpreadCanvasView(book: book,
                                     spread: spreads[index],
                                     pageWidth: size.pageWidth,
                                     pageHeight: size.pageHeight,
                                     drawingRevision: drawingStore.revision,
                                     showDrawing: true,
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
                               showDrawing: true,
                               theme: theme)
            }
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
        .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous)
                .stroke(theme.paperBorderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.50), radius: 16, y: 8)
        .overlay {
            if isPenActive && index == unitIndex {
                drawingLayer(book: book, unitIndex: index, size: size)
            }
        }
    }

    // MARK: - 翻页场景

    @ViewBuilder
    private func flippingScene(book: Book, size: ReaderSize, from: Int, forward: Bool) -> some View {
        if viewMode == .spread {
            spreadFlippingScene(book: book, size: size, from: from, forward: forward)
        } else {
            singleFlippingScene(book: book, size: size, from: from, forward: forward)
        }
    }

    /// 双页模式：翻动纸 = 当前跨页的一半，绕书脊转到另一侧
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
                // 底层：目标跨页
                SpreadCanvasView(book: book,
                                 spread: toSpread,
                                 pageWidth: pw,
                                 pageHeight: ph,
                                 drawingRevision: drawingStore.revision,
                                 showDrawing: true,
                                 theme: theme)
                    .frame(width: pw * 2, height: ph)

                // 当前跨页不参与翻转的那一半（保持不动）
                if forward {
                    pageOrPaper(book: book, index: fromSides.left, size: size)
                        .position(x: pw / 2, y: ph / 2)
                } else {
                    pageOrPaper(book: book, index: fromSides.right, size: size)
                        .position(x: pw * 1.5, y: ph / 2)
                }

                // 翻动纸
                if forward {
                    FlipCard(front: pageOrPaper(book: book, index: fromSides.right, size: size),
                             back: pageOrPaper(book: book, index: toSides.left, size: size),
                             angle: -Double(flipProgress) * 180,
                             anchor: .leading,
                             perspective: 0.32,
                             dimming: theme.flipDimming,
                             paperColor: theme.paperColor,
                             borderColor: theme.paperBorderColor)
                        .frame(width: pw, height: ph)
                        .position(x: pw * 1.5, y: ph / 2)
                } else {
                    FlipCard(front: pageOrPaper(book: book, index: fromSides.left, size: size),
                             back: pageOrPaper(book: book, index: toSides.right, size: size),
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
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.50), radius: 16, y: 8)
        }
    }

    /// 单页模式：翻动纸绕外侧装订边翻出去，露出新页
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
            .clipShape(RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: bookCornerRadius, style: .continuous)
                    .stroke(theme.paperBorderColor, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.50), radius: 16, y: 8)
        }
    }

    /// 取某一页的渲染，越界则退回纸张
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

    // MARK: - 尺寸计算

    struct ReaderSize {
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var containerWidth: CGFloat
        var containerHeight: CGFloat
    }

    /// 让书尽量占满可用空间。
    /// 编辑模式：完全铺满，不留白。
    /// 浏览模式：留一点点边距，让圆角与投影可见。
    private func readerSize(in container: CGSize, book: Book) -> ReaderSize {
        let ratio = max(book.pageAspectRatio, 0.4)

        let hInset: CGFloat = isPenActive ? 0 : 8
        let vInset: CGFloat = isPenActive ? 0 : (viewMode == .spread ? 10 : 16)

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
        // 浏览时明显圆角，编辑时收窄一点（避免削掉画面边缘）
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
            undoTrigger: undoTrigger,
            redoTrigger: redoTrigger,
            clearTrigger: clearTrigger,
            onDrawingChanged: { newDrawing in
                drawingStore.save(newDrawing, bookId: book.id, spreadIndex: sIndex)
                handleAutoAppend(book: book, spreadIndex: sIndex, drawing: newDrawing)
            },
            onDrawingStateChanged: { drawing in
                isDrawingNow = drawing
            }
        )
        .frame(width: logical.width, height: logical.height)
        .scaleEffect(scale, anchor: .topLeading)

        Color.clear
            .frame(width: size.containerWidth, height: size.containerHeight)
            .overlay(alignment: .topLeading) {
                canvas.offset(x: showRightHalf ? -size.pageWidth : 0)
            }
            .clipped()
            .allowsHitTesting(true)
    }

    private var currentTool: PKTool {
        switch penKind {
        case .eraser:
            return PKEraserTool(.vector)
        case .pen:
            return PKInkingTool(.pen,
                                color: UIColor(penColorEnum.color),
                                width: penWidth.rawValue)
        case .marker:
            return PKInkingTool(.marker,
                                color: UIColor(penColorEnum.color).withAlphaComponent(0.55),
                                width: penWidth.rawValue * 2.5)
        case .pencil:
            return PKInkingTool(.pencil,
                                color: UIColor(penColorEnum.color),
                                width: penWidth.rawValue)
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

    /// 编辑且"手指也能画"时，手指要留给画笔，不能翻页
    private var pagingEnabled: Bool {
        !(isPenActive && !settings.pencilOnlyDrawMode)
    }

    /// 边缘点击翻页：编辑模式下只在"仅笔"时启用，避免挡住绘制
    private var edgeTapActive: Bool {
        settings.edgeTapTurn && (!isPenActive || settings.pencilOnlyDrawMode)
    }

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard pagingEnabled, let book else { return }
                guard !isFlipping else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.4 else { return }

                let forward = shouldTurnForward(dx: dx)
                let count = readerUnitCount(book: book)
                let clamped = min(max(unitIndex, 0), max(count - 1, 0))
                let canTurn = forward ? clamped < count - 1 : clamped > 0
                guard canTurn else { return }

                if !isFlipping {
                    flipFromIndex = clamped
                }
                flipForward = forward
                isFlipping = true
                flipProgress = min(max(abs(dx) / 260, 0), 1)
            }
            .onEnded { _ in
                guard let book else {
                    resetFlip()
                    return
                }
                guard isFlipping else {
                    flipProgress = 0
                    return
                }

                if flipProgress > commitThreshold {
                    let remaining = flipDuration * Double(1 - flipProgress)
                    withAnimation(.easeOut(duration: max(remaining, 0.08))) {
                        flipProgress = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(remaining, 0.08)) {
                        finishFlip(book: book)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.26)) {
                        flipProgress = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                        isFlipping = false
                    }
                }
            }
    }

    private func shouldTurnForward(dx: CGFloat) -> Bool {
        let direction = book?.bindingDirection ?? .leftToRight
        return direction == .leftToRight ? (dx < 0) : (dx > 0)
    }

    @ViewBuilder
    private func edgeTapZone(alignment: Alignment, book: Book) -> some View {
        if edgeTapActive {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 72)
                .frame(maxHeight: .infinity)
                .onTapGesture {
                    if alignment == .leading {
                        goBackward()
                    } else {
                        goForward()
                    }
                }
        }
    }

    // MARK: - 翻页执行

    private func beginFlip(forward: Bool, book: Book) {
        let count = readerUnitCount(book: book)
        let clamped = min(max(unitIndex, 0), max(count - 1, 0))
        let canTurn = forward ? clamped < count - 1 : clamped > 0
        guard canTurn, !isFlipping else { return }

        flipFromIndex = clamped
        flipForward = forward
        isFlipping = true
        flipProgress = 0

        playHaptic()

        withAnimation(.easeInOut(duration: flipDuration)) {
            flipProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + flipDuration) {
            finishFlip(book: book)
        }
    }

    private func finishFlip(book: Book) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if flipForward {
                unitIndex = min(flipFromIndex + 1, max(readerUnitCount(book: book) - 1, 0))
            } else {
                unitIndex = max(flipFromIndex - 1, 0)
            }
            flipProgress = 0
            isFlipping = false
        }
        didAutoAppend = false
    }

    private func resetFlip() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            flipProgress = 0
            isFlipping = false
        }
    }

    private func playHaptic() {
        guard settings.pageTurnSound else {
            // 默认静音：不发声，只给轻微触觉
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - 导航

    private func goForward() {
        guard let book else { return }
        guard !isFlipping else { return }
        beginFlip(forward: true, book: book)
    }

    private func goBackward() {
        guard let book else { return }
        guard !isFlipping else { return }
        beginFlip(forward: false, book: book)
    }

    private func clampPosition() {
        guard let book else { return }
        unitIndex = min(max(unitIndex, 0), max(readerUnitCount(book: book) - 1, 0))
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

        VStack(spacing: 2) {
            ScrubberView(count: count,
                         index: unitIndex,
                         scrubbing: $scrubbing) { target in
                resetFlip()
                unitIndex = min(max(target, 0), max(count - 1, 0))
            }
            .padding(.horizontal, 22)

            HStack(spacing: 14) {
                Button { goBackward() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(unitIndex <= 0 || isFlipping)

                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .semibold))
                }
                .disabled(unitIndex >= count - 1 || isFlipping)

                Spacer()

                // 页码：右下角，小号
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
        .padding(.bottom, 6)
        .opacity(isFlipping ? 0.6 : 1)
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

    // MARK: - 拖动进度条时的浮层预览

    @ViewBuilder
    private func scrubPreview(book: Book, size: ReaderSize) -> some View {
        if let target = scrubbing, !book.pages.isEmpty {
            VStack(spacing: 10) {
                Text(previewLabel(book: book, unit: target))
                    .font(.headline)
                    .foregroundStyle(.white)

                Group {
                    if viewMode == .spread {
                        let spreads = SpreadLayout.spreads(for: book)
                        if spreads.indices.contains(target) {
                            SpreadCanvasView(book: book,
                                             spread: spreads[target],
                                             pageWidth: size.pageWidth,
                                             pageHeight: size.pageHeight,
                                             drawingRevision: drawingStore.revision,
                                             showDrawing: true,
                                             theme: theme)
                        }
                    } else if book.pages.indices.contains(target) {
                        SinglePageView(book: book,
                                       pageIndex: target,
                                       pageWidth: size.pageWidth,
                                       pageHeight: size.pageHeight,
                                       drawingRevision: drawingStore.revision,
                                       showDrawing: true,
                                       theme: theme)
                    }
                }
                .frame(width: previewSize(size: size).width,
                       height: previewSize(size: size).height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 12)
            }
            .padding(16)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 24)
            .allowsHitTesting(false)
        }
    }

    private func previewSize(size: ReaderSize) -> CGSize {
        let maxW: CGFloat = viewMode == .spread ? 340 : 230
        let maxH: CGFloat = 380
        let w = min(size.containerWidth, maxW)
        let h = w * (size.containerHeight / max(size.containerWidth, 1))
        if h > maxH {
            return CGSize(width: w * (maxH / h), height: maxH)
        }
        return CGSize(width: w, height: h)
    }

    private func previewLabel(book: Book, unit: Int) -> String {
        if viewMode == .spread {
            let count = SpreadLayout.spreads(for: book).count
            let clamped = min(max(unit, 0), max(count - 1, 0))
            let start = clamped * 2 + 1
            let end = min(start + 1, book.pages.count)
            return "跨页 \(start)-\(end)"
        } else {
            return "第 \(min(max(unit, 0), max(book.pages.count - 1, 0)) + 1) 页"
        }
    }

    // MARK: - 笔工具栏

    private var penToolbar: some View {
        HStack(spacing: 11) {
            ForEach(PenKind.allCases, id: \.self) { kind in
                Button { penKind = kind } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(penKind == kind
                                    ? Color.accentColor.opacity(0.34)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 18)

            HStack(spacing: 7) {
                ForEach(PenColor.allCases, id: \.self) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(penColorEnum == c ? 0.95 : 0.14),
                                lineWidth: penColorEnum == c ? 2.5 : 1
                            )
                        )
                        .onTapGesture { penColorEnum = c }
                }
            }
            .opacity(penKind == .eraser ? 0.28 : 1)
            .allowsHitTesting(penKind != .eraser)

            Divider().frame(height: 18)

            ForEach(PenWidth.allCases, id: \.self) { w in
                Button { penWidth = w } label: {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: w.dotSize, height: w.dotSize)
                        .frame(width: 26, height: 26)
                        .background(penWidth == w
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 18)

            Button { undoTrigger += 1 } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            Button { redoTrigger += 1 } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            Button { clearTrigger += 1 } label: {
                Image(systemName: "trash")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.black.opacity(0.68), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: - 导航栏工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isPenActive.toggle()
                isDrawingNow = false
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
