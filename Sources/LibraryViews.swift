import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @State private var path = NavigationPath()
    @State private var showNewBookAlert = false
    @State private var newBookTitle = ""
    @State private var bookToRename: Book?
    @State private var renameTitle = ""
    @State private var showSettings = false
    @State private var coverEditingBook: Book?
    @State private var carouselIndex = 0

    // PDF 导入
    @State private var showPDFPicker = false
    @State private var pdfFileRef: PDFFileRef?

    // 图片批量导入
    @State private var showPhotoImport = false

    // 翻开动画
    @State private var openingBook: Book?
    @State private var openProgress: CGFloat = 0
    @State private var overlayOpacity: Double = 1
    @State private var isOpening = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    shelf
                }
            }
            .navigationTitle("我的书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            newBookTitle = ""
                            showNewBookAlert = true
                        } label: {
                            Label("新建空白画册", systemImage: "book")
                        }

                        Divider()

                        Button {
                            delayed { showPDFPicker = true }
                        } label: {
                            Label("导入 PDF", systemImage: "doc.richtext")
                        }

                        Button {
                            delayed { showPhotoImport = true }
                        } label: {
                            Label("批量导入图片", systemImage: "photo.stack")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BookReaderView(bookID: id)
            }
        }
        .overlay {
            if let openingBook {
                BookOpeningOverlay(book: openingBook, progress: openProgress)
                    .opacity(overlayOpacity)
                    .allowsHitTesting(false)
            }
        }
        // ⚠️ 呈现类修饰符挂在 NavigationStack 最外层
        .fileImporter(isPresented: $showPDFPicker,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: false) { result in
            handlePDFSelection(result)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settingsStore)
        }
        .sheet(item: $coverEditingBook) { book in
            CoverPickerView(
                initialStyle: book.coverStyle,
                hasCustomImage: book.customCoverImage != nil,
                onStyle: { style in
                    var updated = book
                    updated.coverStyle = style
                    library.update(updated)
                },
                onCustomImage: { name in
                    var updated = book
                    updated.customCoverImage = name
                    library.update(updated)
                }
            )
        }
        .sheet(item: $pdfFileRef) { ref in
            PDFImportSheet(fileURL: ref.url)
                .environmentObject(library)
        }
        .sheet(isPresented: $showPhotoImport) {
            PhotoImportSheet()
                .environmentObject(library)
        }
        .alert("新建画册", isPresented: $showNewBookAlert) {
            TextField("画册名称", text: $newBookTitle)
            Button("取消", role: .cancel) {}
            Button("创建") {
                library.createBook(title: newBookTitle)
                carouselIndex = 0
            }
        }
        .alert("重命名画册", isPresented: renameAlertBinding) {
            TextField("画册名称", text: $renameTitle)
            Button("取消", role: .cancel) { bookToRename = nil }
            Button("保存") {
                if var b = bookToRename {
                    let trimmed = renameTitle
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { b.title = trimmed }
                    library.update(b)
                }
                bookToRename = nil
            }
        }
        .onChange(of: library.books.count) { count in
            carouselIndex = min(max(carouselIndex, 0), max(count - 1, 0))
        }
    }

    private func delayed(_ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { bookToRename != nil },
            set: { if !$0 { bookToRename = nil } }
        )
    }

    // MARK: - 居中书架

    private var shelf: some View {
        VStack(spacing: 0) {
            BookCarousel(books: library.books,
                         index: $carouselIndex,
                         onOpen: { book in
                             openBook(book)
                         },
                         onCover: { book in
                             coverEditingBook = book
                         },
                         onRename: { book in
                             bookToRename = book
                             renameTitle = book.title
                         },
                         onDelete: { book in
                             library.delete(book)
                         })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            currentBookInfo
        }
    }

    @ViewBuilder
    private var currentBookInfo: some View {
        if library.books.indices.contains(carouselIndex) {
            let book = library.books[carouselIndex]
            VStack(spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(book.pages.count) 页")
                    if !book.outline.isEmpty {
                        Text("·")
                        Text("\(book.outline.count) 条目")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("书架还是空的")
                .font(.title3)

            Button("新建第一本画册") {
                newBookTitle = ""
                showNewBookAlert = true
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 12) {
                Button("导入 PDF") {
                    delayed { showPDFPicker = true }
                }
                .buttonStyle(.bordered)

                Button("批量导入图片") {
                    delayed { showPhotoImport = true }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 翻开动画

    private func openBook(_ book: Book) {
        guard !isOpening else { return }
        isOpening = true

        openingBook = book
        openProgress = 0
        overlayOpacity = 1

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // 封面绕左边缘翻开
        withAnimation(.easeInOut(duration: 0.78)) {
            openProgress = 1
        }

        // 翻开到 92% 时推入阅读器
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
            path.append(book.id)
            withAnimation(.easeOut(duration: 0.20)) {
                overlayOpacity = 0
            }
        }

        // 收尾
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            openingBook = nil
            openProgress = 0
            overlayOpacity = 1
            isOpening = false
        }
    }

    // MARK: - PDF 选择

    private func handlePDFSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            break

        case .success(let urls):
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let dest = FileStorage.documents.appendingPathComponent("import-temp.pdf")
            try? FileManager.default.removeItem(at: dest)

            let target: URL
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                target = dest
            } else {
                target = url
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pdfFileRef = PDFFileRef(url: target)
            }
        }
    }
}

// MARK: - 翻开动画视图

struct BookOpeningOverlay: View {
    let book: Book
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width * 0.62, 520)
            let h = w * 1.38

            ZStack {
                // 压暗背景
                Color.black
                    .opacity(0.55 * Double(min(progress * 1.4, 1)))
                    .ignoresSafeArea()

                ZStack {
                    // 里面露出的第一页
                    firstPage(width: w, height: h)

                    // 封面绕左边缘翻开
                    FlipCard(front: AnyView(NotebookCoverView(book: book, width: w)),
                             back: AnyView(backSide(width: w, height: h)),
                             angle: -178 * Double(progress),
                             anchor: .leading,
                             perspective: 0.30,
                             dimming: 0.08,
                             paperColor: PaperStyle.fill,
                             borderColor: PaperStyle.border)
                        .frame(width: w, height: h)
                }
                .scaleEffect(1 + 0.07 * progress)
                .offset(y: -24 * progress)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func firstPage(width: CGFloat, height: CGFloat) -> some View {
        let page = book.pages.first ?? Page.blank()
        return PageContentView(page: page,
                               size: CGSize(width: width, height: height),
                               theme: .classic)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func backSide(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            PaperStyle.fill

            LinearGradient(
                colors: [Color.black.opacity(0.06),
                         Color.clear,
                         Color.black.opacity(0.06)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .frame(width: width, height: height)
    }
}
