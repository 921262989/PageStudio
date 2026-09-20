import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PencilKit

// MARK: - 单页内容

struct PageContentView: View {
    let page: Page
    let size: CGSize

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

// MARK: - 跨页视图

/// 双页展开视图。整个跨页作为整体渲染 —— 这是「跨页绘制无接缝」的地基。
struct SpreadView: View {
    let book: Book
    let spread: Spread
    let pageWidth: CGFloat
    let pageHeight: CGFloat

    private var pageSize: CGSize {
        CGSize(width: pageWidth, height: pageHeight)
    }

    private var spreadSize: CGSize {
        CGSize(width: pageWidth * 2, height: pageHeight)
    }

    var body: some View {
        Group {
            if let index = spread.fullSpreadPageIndex, book.pages.indices.contains(index) {
                PageContentView(page: book.pages[index], size: spreadSize)
            } else {
                let sides = SpreadLayout.visualSides(of: spread, binding: book.bindingDirection)
                HStack(spacing: 0) {
                    slot(pageIndex: sides.left)
                    slot(pageIndex: sides.right)
                }
                .overlay(SpineView())
            }
        }
        .frame(width: spreadSize.width, height: spreadSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private func slot(pageIndex: Int?) -> some View {
        if let pageIndex, book.pages.indices.contains(pageIndex) {
            PageContentView(page: book.pages[pageIndex], size: pageSize)
        } else {
            PaperView()
                .frame(width: pageSize.width, height: pageSize.height)
        }
    }
}

// MARK: - 单页视图

struct SinglePageView: View {
    let book: Book
    let pageIndex: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat

    private var pageSize: CGSize {
        CGSize(width: pageWidth, height: pageHeight)
    }

    var body: some View {
        Group {
            if book.pages.indices.contains(pageIndex) {
                let page = book.pages[pageIndex]
                if page.occupiesSpread {
                    ZStack(alignment: .topLeading) {
                        PageContentView(page: page,
                                        size: CGSize(width: pageWidth * 2,
                                                     height: pageHeight))
                    }
                    .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
                    .clipped()
                } else {
                    PageContentView(page: page, size: pageSize)
                }
            } else {
                PaperView()
                    .frame(width: pageWidth, height: pageHeight)
            }
        }
        .frame(width: pageWidth, height: pageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

// MARK: - 阅读器

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
    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var clearTrigger = 0

    // 自动续页
    @State private var didAutoAppend = false

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
                    mainContent(book: book, container: geo.size)
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
                      maxSelectionCount: 100,
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

    // MARK: - 主内容

    @ViewBuilder
    private func mainContent(book: Book, container: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            if book.pages.isEmpty {
                emptyHint
            } else {
                let unitCount = readerUnitCount(book: book)
                let size = readerSize(in: container, book: book)

                CurlPageController(
                    pageCount: unitCount,
                    currentIndex: $unitIndex,
                    onTapLeft: {
                        guard settings.edgeTapTurn else { return }
                        goBackward()
                    },
                    onTapRight: {
                        guard settings.edgeTapTurn else { return }
                        goForward()
                    }
                ) { index in
                    unitView(book: book, unitIndex: index, size: size)
                }
                .id("\(viewMode.rawValue)-\(book.pages.count)")
                .frame(width: size.containerWidth, height: size.containerHeight)
            }

            Spacer(minLength: 8)

            if isPenActive {
                penToolbar
            }

            bottomBar(book: book)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 阅读单元

    /// 双页模式：一个跨页 = 一个单元；单页模式：一个页面 = 一个单元
    private func readerUnitCount(book: Book) -> Int {
        if viewMode == .spread {
            return SpreadLayout.spreads(for: book).count
        } else {
            return book.pages.count
        }
    }

    struct ReaderSize {
        let pageWidth: CGFloat
        let pageHeight: CGFloat
        var containerWidth: CGFloat
        var containerHeight: CGFloat
    }

    private func readerSize(in container: CGSize, book: Book) -> ReaderSize {
        let horizontalPadding: CGFloat = (viewMode == .spread) ? 60 : 90
        let verticalPadding: CGFloat = isPenActive ? 200 : 140

        let availableWidth = max(container.width - horizontalPadding, 120)
        let availableHeight = max(container.height - verticalPadding, 120)
        let slots: CGFloat = (viewMode == .spread) ? 2 : 1

        var width = availableWidth / slots
        var height = width * book.pageAspectRatio
        if height > availableHeight {
            height = availableHeight
            width = height / book.pageAspectRatio
        }

        return ReaderSize(
            pageWidth: width,
            pageHeight: height,
            containerWidth: viewMode == .spread ? width * 2 : width,
            containerHeight: height
        )
    }

    @ViewBuilder
    private func unitView(book: Book, unitIndex index: Int, size: ReaderSize) -> some View {
        ZStack {
            // 底图
            if viewMode == .spread {
                let spreads = SpreadLayout.spreads(for: book)
                if spreads.indices.contains(index) {
                    SpreadView(book: book,
                               spread: spreads[index],
                               pageWidth: size.pageWidth,
                               pageHeight: size.pageHeight)
                }
            } else {
                if book.pages.indices.contains(index) {
                    SinglePageView(book: book,
                                   pageIndex: index,
                                   pageWidth: size.pageWidth,
                                   pageHeight: size.pageHeight)
                }
            }

            // 绘制层（跨页尺寸）
            if isPenActive {
                drawingLayer(book: book, unitIndex: index, size: size)
                    .id("\(book.id.uuidString)-\(spreadIndexForUnit(index, book: book))")
            }
        }
        .frame(width: size.containerWidth, height: size.containerHeight)
    }

    // MARK: - 绘制层

    @ViewBuilder
    private func drawingLayer(book: Book, unitIndex index: Int, size: ReaderSize) -> some View {
        let sIndex = spreadIndexForUnit(index, book: book)
        let canvasSize = CGSize(width: size.pageWidth * 2, height: size.pageHeight)

        let canvas = DrawingCanvas(
            canvasSize: canvasSize,
            initialDrawing: drawingStore.load(bookId: book.id, spreadIndex: sIndex),
            pencilOnly: settings.pencilOnlyDrawMode,
            tool: currentTool,
            undoTrigger: undoTrigger,
            redoTrigger: redoTrigger,
            clearTrigger: clearTrigger,
            onDrawingChanged: { newDrawing in
                drawingStore.save(newDrawing, bookId: book.id, spreadIndex: sIndex)
                handleAutoAppend(book: book, spreadIndex: sIndex, drawing: newDrawing)
            }
        )
        .frame(width: canvasSize.width, height: canvasSize.height)

        if viewMode == .spread {
            canvas
        } else {
            // 单页模式：跨页画布只显示一半，坐标完全一致
            let showRight = isRightPage(unitIndex: index, book: book)
            ZStack(alignment: .topLeading) {
                canvas
                    .offset(x: showRight ? -size.pageWidth : 0)
            }
            .frame(width: size.pageWidth, height: size.pageHeight, alignment: .topLeading)
            .clipped()
        }
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

    /// 当前单元对应哪个跨页 —— 笔迹按跨页存储
    private func spreadIndexForUnit(_ index: Int, book: Book) -> Int {
        if viewMode == .spread {
            return index
        } else {
            return SpreadLayout.spreadIndex(containingPage: index, in: book)
        }
    }

    /// 当前页是不是它所属跨页的右页
    private func isRightPage(unitIndex index: Int, book: Book) -> Bool {
        let spreads = SpreadLayout.spreads(for: book)
        guard let spread = spreads.first(where: { $0.pageIndices.contains(index) }) else {
            return false
        }
        let sides = SpreadLayout.visualSides(of: spread, binding: book.bindingDirection)
        return sides.right == index
    }

    // MARK: - 自动续页

    private func handleAutoAppend(book: Book, spreadIndex: Int, drawing: PKDrawing) {
        guard settings.autoAppendPage else { return }
        guard !drawing.strokes.isEmpty else { return }
        guard !didAutoAppend else { return }

        let spreads = SpreadLayout.spreads(for: book)
        guard spreadIndex == spreads.count - 1 else { return }

        var updated = book
        updated.pages.append(.blank())
        library.update(updated)
        didAutoAppend = true
    }

    // MARK: - 手势 / 翻页

    private func goForward() {
        guard let book else { return }
        if viewMode == .spread {
            let count = SpreadLayout.spreads(for: book).count
            if unitIndex + 1 < count { unitIndex += 1 }
        } else {
            if unitIndex + 1 < book.pages.count { unitIndex += 1 }
        }
    }

    private func goBackward() {
        if unitIndex > 0 { unitIndex -= 1 }
    }

    private func canGoForward(book: Book) -> Bool {
        if viewMode == .spread {
            return unitIndex < SpreadLayout.spreads(for: book).count - 1
        } else {
            return unitIndex < book.pages.count - 1
        }
    }

    private func canGoBackward(book: Book) -> Bool {
        _ = book
        return unitIndex > 0
    }

    private func clampPosition() {
        guard let book else { return }
        let count = readerUnitCount(book: book)
        unitIndex = min(max(unitIndex, 0), max(count - 1, 0))
    }

    private func initialize(container: CGSize) {
        guard !didInitialize, let book else { return }
        didInitialize = true
        let isPortrait = container.height > container.width
        viewMode = isPortrait ? .single : book.defaultViewMode
        unitIndex = 0
    }

    /// 单页 / 双页切换，阅读位置正确换算
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

    // MARK: - 底部栏

    private func bottomBar(book: Book) -> some View {
        HStack(spacing: 26) {
            Button { goBackward() } label: {
                Image(systemName: "chevron.backward").font(.title3)
            }
            .disabled(!canGoBackward(book: book))

            Text(positionText(book: book))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 160)

            Button { goForward() } label: {
                Image(systemName: "chevron.forward").font(.title3)
            }
            .disabled(!canGoForward(book: book))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(Color.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 10)
    }

    private func positionText(book: Book) -> String {
        if viewMode == .spread {
            let count = SpreadLayout.spreads(for: book).count
            let clamped = min(max(unitIndex, 0), max(count - 1, 0))
            return "跨页 \(clamped + 1) / \(count)"
        } else {
            let clamped = min(max(unitIndex, 0), max(book.pages.count - 1, 0))
            return "第 \(clamped + 1) 页 / \(book.pages.count)"
        }
    }

    // MARK: - 笔工具栏

    private var penToolbar: some View {
        HStack(spacing: 14) {
            ForEach(PenKind.allCases, id: \.self) { kind in
                Button {
                    penKind = kind
                } label: {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 17))
                        .frame(width: 36, height: 36)
                        .background(penKind == kind
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 22)

            HStack(spacing: 9) {
                ForEach(PenColor.allCases, id: \.self) { c in
                    Circle()
                        .fill(c.color)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(
                                Color.primary.opacity(penColorEnum == c ? 0.9 : 0.15),
                                lineWidth: penColorEnum == c ? 2.5 : 1
                            )
                        )
                        .onTapGesture { penColorEnum = c }
                }
            }
            .opacity(penKind == .eraser ? 0.3 : 1)
            .allowsHitTesting(penKind != .eraser)

            Divider().frame(height: 22)

            ForEach(PenWidth.allCases, id: \.self) { w in
                Button {
                    penWidth = w
                } label: {
                    Circle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: w.dotSize, height: w.dotSize)
                        .frame(width: 30, height: 30)
                        .background(penWidth == w
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 22)

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
        .font(.system(size: 16))
        .foregroundStyle(.white)
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
        .background(Color.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 8)
    }

    // MARK: - 工具栏（导航栏）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                isPenActive.toggle()
            } label: {
                Image(systemName: isPenActive ? "pencil.circle.fill" : "pencil.circle")
                    .font(.title3)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
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

                if let name = try? FileStorage.saveImageData(data, preferredExtension: ext) {
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

        if viewMode == .spread {
            unitIndex = SpreadLayout.spreadIndex(containingPage: startIndex, in: currentBook)
        } else {
            unitIndex = startIndex
        }
    }
}
