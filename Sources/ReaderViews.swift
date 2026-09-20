import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 单页内容

/// 渲染单个页面槽位的内容：纸张 + 图片（带适配变换）
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

    let bookID: UUID

    @State private var spreadIndex = 0
    @State private var pageIndex = 0
    @State private var viewMode: ViewMode = .spread
    @State private var didInitialize = false

    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importOccupiesSpread = false
    @State private var importMessage: String? = nil

    private var book: Book? { library.book(id: bookID) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReaderBackground()
                if let book {
                    content(for: book, container: geo.size)
                } else {
                    Text("这本画册已被删除")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { initializeIfNeeded(container: geo.size) }
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

    @ViewBuilder
    private func content(for book: Book, container: CGSize) -> some View {
        let spreads = SpreadLayout.spreads(for: book)
        let clampedSpread = min(max(spreadIndex, 0), max(spreads.count - 1, 0))
        let clampedPage = min(max(pageIndex, 0), max(book.pages.count - 1, 0))

        VStack(spacing: 0) {
            Spacer(minLength: 12)

            if book.pages.isEmpty {
                emptyHint
            } else if viewMode == .spread {
                let size = pageSize(in: container, mode: .spread,
                                    ratio: book.pageAspectRatio)
                SpreadView(book: book,
                           spread: spreads[clampedSpread],
                           pageWidth: size.width,
                           pageHeight: size.height)
            } else {
                let size = pageSize(in: container, mode: .single,
                                    ratio: book.pageAspectRatio)
                SinglePageView(book: book,
                               pageIndex: clampedPage,
                               pageWidth: size.width,
                               pageHeight: size.height)
            }

            Spacer(minLength: 12)
            bottomBar(book: book, spreads: spreads)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(turnGesture)
        .simultaneousGesture(edgeTapGesture(container: container))
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

    private func pageSize(in container: CGSize, mode: ViewMode, ratio: Double) -> CGSize {
        let horizontalPadding: CGFloat = (mode == .spread) ? 60 : 90
        let verticalPadding: CGFloat = 140

        let availableWidth = max(container.width - horizontalPadding, 120)
        let availableHeight = max(container.height - verticalPadding, 120)
        let slots: CGFloat = (mode == .spread) ? 2 : 1

        var width = availableWidth / slots
        var height = width * ratio
        if height > availableHeight {
            height = availableHeight
            width = height / ratio
        }
        return CGSize(width: width, height: height)
    }

    private var turnGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                if shouldTurnForward(dx: dx) {
                    goForward()
                } else {
                    goBackward()
                }
            }
    }

    private func shouldTurnForward(dx: CGFloat) -> Bool {
        let direction = book?.bindingDirection ?? .leftToRight
        return direction == .leftToRight ? (dx < 0) : (dx > 0)
    }

    private func edgeTapGesture(container: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let edgeWidth = max(container.width / 5, 60)
                if value.location.x < edgeWidth {
                    goBackward()
                } else if value.location.x > container.width - edgeWidth {
                    goForward()
                }
            }
    }

    private func goForward() {
        guard let book else { return }
        let spreads = SpreadLayout.spreads(for: book)
        if viewMode == .spread {
            let current = min(max(spreadIndex, 0), max(spreads.count - 1, 0))
            if current + 1 < spreads.count { spreadIndex = current + 1 }
        } else {
            if pageIndex + 1 < book.pages.count { pageIndex += 1 }
        }
    }

    private func goBackward() {
        if viewMode == .spread {
            if spreadIndex > 0 { spreadIndex -= 1 }
        } else {
            if pageIndex > 0 { pageIndex -= 1 }
        }
    }

    private func canGoForward(book: Book, spreads: [Spread]) -> Bool {
        if viewMode == .spread {
            return spreadIndex < spreads.count - 1
        } else {
            return pageIndex < book.pages.count - 1
        }
    }

    private func canGoBackward(book: Book, spreads: [Spread]) -> Bool {
        _ = book
        _ = spreads
        return viewMode == .spread ? spreadIndex > 0 : pageIndex > 0
    }

    private func clampPosition() {
        guard let book else { return }
        let spreads = SpreadLayout.spreads(for: book)
        spreadIndex = min(max(spreadIndex, 0), max(spreads.count - 1, 0))
        pageIndex = min(max(pageIndex, 0), max(book.pages.count - 1, 0))
    }

    private func initializeIfNeeded(container: CGSize) {
        guard !didInitialize, let book else { return }
        didInitialize = true
        let isPortrait = container.height > container.width
        viewMode = isPortrait ? .single : book.defaultViewMode
        spreadIndex = 0
        pageIndex = 0
    }

    private func toggleViewMode() {
        guard let book else { return }
        if viewMode == .spread {
            let spreads = SpreadLayout.spreads(for: book)
            let current = min(max(spreadIndex, 0), max(spreads.count - 1, 0))
            if let firstPage = spreads[current].pageIndices.first {
                pageIndex = firstPage
            }
            viewMode = .single
        } else {
            spreadIndex = SpreadLayout.spreadIndex(containingPage: pageIndex, in: book)
            viewMode = .spread
        }
    }

    private func bottomBar(book: Book, spreads: [Spread]) -> some View {
        HStack(spacing: 26) {
            Button { goBackward() } label: {
                Image(systemName: "chevron.backward").font(.title3)
            }
            .disabled(!canGoBackward(book: book, spreads: spreads))

            Text(positionText(book: book, spreads: spreads))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 150)

            Button { goForward() } label: {
                Image(systemName: "chevron.forward").font(.title3)
            }
            .disabled(!canGoForward(book: book, spreads: spreads))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(Color.black.opacity(0.35), in: Capsule())
        .padding(.bottom, 14)
    }

    private func positionText(book: Book, spreads: [Spread]) -> String {
        if viewMode == .spread {
            let clamped = min(max(spreadIndex, 0), max(spreads.count - 1, 0))
            return "跨页 \(clamped + 1) / \(spreads.count)"
        } else {
            let clamped = min(max(pageIndex, 0), max(book.pages.count - 1, 0))
            return "第 \(clamped + 1) 页 / \(book.pages.count)"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

        if viewMode == .spread {
            spreadIndex = SpreadLayout.spreadIndex(containingPage: startIndex,
                                                   in: currentBook)
        } else {
            pageIndex = startIndex
        }
    }
}
