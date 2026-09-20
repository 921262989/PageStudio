import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var penKind: PenKind = .pen
    @State private var penColorEnum: PenColor = .black
    @State private var penWidth: PenWidth = .medium
    @State private var isDrawingNow = false
    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0

    @State private var didAutoAppend = false

    // 面板
    @State private var scrubbing: Int? = nil
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReaderBackground()

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
                                   currentPageIndex: currentPageIndex(book: book)) { pageIdx in
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
                    set: { if !\$0 { importMessage = nil } }
               )) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: - 布局

    @ViewBuilder
    private func main(book: Book, container: CGSize) -> some View {
        VStack(spacing: 0) {
            GeometryReader { inner in
                bookArea(book: book, available: inner.size)
            }
            .padding(.horizontal, isPenActive ? 0 : 10)
            .padding(.top, isPenActive ? 0 : 8)

            if !isPenActive && !book.pages.isEmpty {
                bottomBar(book: book)
            }
        }
        .frame(width: container.width, height: container.height)
    }

    @ViewBuilder
    private func bookArea(book: Book, available: CGSize) -> some View {
        let size = readerSize(in: available, book: book)
        let count = readerUnitCount(book: book)

        ZStack {
            if book.pages.isEmpty {
                emptyHint
            } else {
                CurlPageController(pageCount: count,
                                   currentIndex: $unitIndex,
                                   interactivePaging: pagingEnabled,
                                   onTapLeft: {
                                       guard settings.edgeTapTurn else { return }
                                       goBackward()
                                   },
                                   onTapRight: {
                                       guard settings.edgeTapTurn else { return }
                                       goForward()
                                   }) { index in
                    unitView(book: book, unitIndex: index, size: size)
                }
                .frame(width: size.containerWidth, height: size.containerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .id(viewMode.rawValue)
            }
        }
        .frame(width: available.width, height: available.height)
        .overlay { scrubPreview(book: book, size: size) }
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

    // MARK: - 尺寸

    struct ReaderSize {
        var pageWidth: CGFloat
        var pageHeight: CGFloat
        var containerWidth: CGFloat
        var containerHeight: CGFloat
    }

    /// 让书尽量占满可用空间：双页时按跨页铺满，单页时按单页铺满
    private func readerSize(in container: CGSize, book: Book) -> ReaderSize {
        let ratio = max(book.pageAspectRatio, 0.4)

        var pw: CGFloat
        var ph: CGFloat

        if viewMode == .spread {
            ph = container.height
            pw = ph / ratio
            if pw * 2 > container.width {
                pw = container.width / 2
                ph = pw * ratio
            }
        } else {
            ph = container.height
            pw = ph / ratio
            if pw > container.width {
                pw = container.width
                ph = pw * ratio
            }
        }

        return ReaderSize(pageWidth: pw,
                          pageHeight: ph,
                          containerWidth: viewMode == .spread ? pw * 2 : pw,
                          containerHeight: ph)
    }

    private func readerUnitCount(book: Book) -> Int {
        viewMode == .spread ? SpreadLayout.spreads(for: book).count : book.pages.count
    }

    // MARK: - 单元内容

    @ViewBuilder
    private func unitView(book: Book, unitIndex index: Int, size: ReaderSize) -> some View {
        let isActiveUnit = isPenActive && index == unitIndex
        let showBakedInk = !(isActiveUnit && isDrawingNow)

        ZStack {
            if viewMode == .spread {
                let spreads = SpreadLayout.spreads(for: book)
                if spreads.indices.contains(index) {
                    SpreadCanvasView(book: book,
                                     spread: spreads[index],
                                     pageWidth: size.pageWidth,
                                     pageHeight: size.pageHeight,
                                     drawingRevision: drawingStore.revision,
                                     showDrawing: showBakedInk)
                } else {
                    PaperView()
                }
            } else {
                SinglePageView(book: book,
                               pageIndex: index,
                               pageWidth: size.pageWidth,
                               pageHeight: size.pageHeight,
                               drawingRevision: drawingStore.revision,
                               showDrawing: showBakedInk)
            }

            if isActiveUnit {
                drawingLayer(book: book, unitIndex: index, size: size)
            }
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
    }

    // MARK: - 绘制层

    @ViewBuilder
    private func drawingLayer(book: Book, unitIndex index: Int, size: ReaderSize) -> some View {
        let sIndex = spreadIndexForUnit(index, book: book)
        let logical = DrawingGeometry.spreadSize(ratio: book.pageAspectRatio)
        let displayWidth = size.pageWidth * 2
        let displayHeight = size.pageHeight
        let scale = displayWidth / logical.width

        let showRightPage = viewMode == .single && isRightPage(unitIndex: index, book: book)

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
                canvas.offset(x: showRightPage ? -size.pageWidth : 0)
            }
            .clipped()
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
        guard let s = SpreadLayout.spread(containingPage: index, in: book) else { return false }
        return SpreadLayout.visualSides(of: s, binding: book.bindingDirection).right == index
    }

    /// 手指＋笔模式下不能用滑动翻页，否则手指画线会和翻页打架
    private var pagingEnabled: Bool {
        !(isPenActive && !settings.pencilOnlyDrawMode)
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

    // MARK: - 导航

    private func goForward() {
        guard let book else { return }
        if viewMode == .spread {
            if unitIndex + 1 < SpreadLayout.spreads(for: book).count { unitIndex += 1 }
        } else {
            if unitIndex + 1 < book.pages.count { unitIndex += 1 }
        }
    }

    private func goBackward() {
        if unitIndex > 0 { unitIndex -= 1 }
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

        VStack(spacing: 4) {
            ScrubberView(count: count,
                         index: unitIndex,
                         scrubbing: $scrubbing) { target in
                unitIndex = min(max(target, 0), max(count - 1, 0))
            }
            .padding(.horizontal, 20)

            HStack(spacing: 16) {
                Button { goBackward() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(unitIndex <= 0)

                Button { goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(unitIndex >= count - 1)

                Spacer()

                Text(positionText(book: book))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.35), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
        }
        .padding(.bottom, 8)
    }

    private func positionText(book: Book) -> String {
        if viewMode == .spread {
            let count = SpreadLayout.spreads(for: book).count
            let clamped = min(max(unitIndex, 0), max(count - 1, 0))
            let start = clamped * 2 + 1
            let end = min(start + 1, book.pages.count)
            return "跨页 \(start)-\(end) / \(count)"
        } else {
            let clamped = min(max(unitIndex, 0), max(book.pages.count - 1, 0))
            return "第 \(clamped + 1) 页 / \(book.pages.count)"
        }
    }

    // MARK: - 拖动时的预览

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
                                             showDrawing: true)
                        }
                    } else if book.pages.indices.contains(target) {
                        SinglePageView(book: book,
                                       pageIndex: target,
                                       pageWidth: size.pageWidth,
                                       pageHeight: size.pageHeight,
                                       drawingRevision: drawingStore.revision,
                                       showDrawing: true)
                    }
                }
                .frame(width: previewSize(size: size).width,
                       height: previewSize(size: size).height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 12)
            }
            .padding(16)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 24)
            .allowsHitTesting(false)
            .opacity(0.98)
        }
    }

    private func previewSize(size: ReaderSize) -> CGSize {
        let maxW: CGFloat = viewMode == .spread ? 320 : 220
        let maxH: CGFloat = 360
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
        HStack(spacing: 12) {
            ForEach(PenKind.allCases, id: \.self) { kind in
                Button { penKind = kind } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 16))
                        .frame(width: 34, height: 34)
                        .background(penKind == kind
                                    ? Color.accentColor.opacity(0.32)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 20)

            HStack(spacing: 8) {
                ForEach(PenColor.allCases, id: \.self) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(penColorEnum == c ? 0.95 : 0.15),
                                lineWidth: penColorEnum == c ? 2.5 : 1
                            )
                        )
                        .onTapGesture { penColorEnum = c }
                }
            }
            .opacity(penKind == .eraser ? 0.28 : 1)
            .allowsHitTesting(penKind != .eraser)

            Divider().frame(height: 20)

            ForEach(PenWidth.allCases, id: \.self) { w in
                Button { penWidth = w } label: {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: w.dotSize, height: w.dotSize)
                        .frame(width: 28, height: 28)
                        .background(penWidth == w
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 20)

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
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Color.black.opacity(0.62), in: Capsule())
        .padding(.bottom, 10)
    }

    // MARK: - 导航栏工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isPenActive.toggle()
                isDrawingNow = false
            } label: {
                Image(systemName: isPenActive ? "pencil.circle.fill" : "pencil.circle")
                    .font(.title3)
            }

            Button {
                showThumbnails = true
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.title3)
            }

            Button {
                showOutline = true
            } label: {
                Image(systemName: "list.bullet.indent")
                    .font(.title3)
            }

            Menu {
                Button {
                    toggleViewMode()
                } label: {
                    Label(viewMode == .spread ? "切换为单页" : "切换为双页",
                          systemImage: viewMode == .spread ? "rectangle.portrait" : "book")
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
                    Label("从照片导入（占整个跨页）", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    importOccupiesSpread = true
                    showFileImporter = true
                } label: {
                    Label("从文件导入（占整个跨页）", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }

        if isPenActive {
            ToolbarItem(placement: .bottomBar) {
                penToolbar
            }
        }
    }

    // MARK: - 导入

    private func importFromPhotos(_ items: [PhotosPickerItem]) async {
        var newPages: [Page] = []
        let occupies = importOccupiesSpread

        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
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

   
