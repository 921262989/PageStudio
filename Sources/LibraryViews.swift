import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书架上的弹窗（合并成一个，避免多 sheet 打架）

enum LibrarySheet: Identifiable {
    case settings
    case cover(Book)
    case pdf(URL)
    case photoImport

    var id: String {
        switch self {
        case .settings:        return "settings"
        case .cover(let b):    return "cover-\(b.id.uuidString)"
        case .pdf(let url):    return "pdf-\(url.lastPathComponent)"
        case .photoImport:     return "photoImport"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @State private var path = NavigationPath()
    @State private var showNewBookAlert = false
    @State private var newBookTitle = ""
    @State private var bookToRename: Book?
    @State private var renameTitle = ""
    @State private var carouselIndex = 0

    /// ⚠️ 只保留这一个 sheet。多个 .sheet 挂在同一视图上，
    ///    iOS 16 只会让最后一个生效 —— 这正是 PDF 导入点了没反应的原因。
    @State private var activeSheet: LibrarySheet?

    @State private var showPDFPicker = false

    private var theme: ReaderTheme { settingsStore.settings.readerTheme }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                ReaderBackground(theme: theme)

                Group {
                    if library.books.isEmpty {
                        emptyState
                    } else {
                        shelf
                    }
                }
            }
            .navigationTitle("我的书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { activeSheet = .settings } label: {
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
                            showPDFPicker = true
                        } label: {
                            Label("导入 PDF", systemImage: "doc.richtext")
                        }

                        Button {
                            activeSheet = .photoImport
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
        }
        // 单一 sheet 出口
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
                    .environmentObject(settingsStore)

            case .cover(let book):
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

            case .pdf(let url):
                PDFImportSheet(fileURL: url)
                    .environmentObject(library)

            case .photoImport:
                PhotoImportSheet()
                    .environmentObject(library)
            }
        }
        // 文件选择器
        .fileImporter(isPresented: $showPDFPicker,
                      allowedContentTypes: [.pdf],
                      allowsMultipleSelection: false) { result in
            handlePDFSelection(result)
        }
        // 深色背景上保证文字可读
        .preferredColorScheme(.dark)
        .onChange(of: library.books.count) { count in
            carouselIndex = min(max(carouselIndex, 0), max(count - 1, 0))
        }
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
                             // 去掉翻开动画，直接进书
                             path.append(book.id)
                         },
                         onCover: { book in
                             activeSheet = .cover(book)
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
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Text("\(book.pages.count) 页")
                    if !book.outline.isEmpty {
                        Text("·")
                        Text("\(book.outline.count) 条目")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.5))

            Text("书架还是空的")
                .font(.title3)
                .foregroundStyle(.white)

            Button("新建第一本画册") {
                newBookTitle = ""
                showNewBookAlert = true
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 12) {
                Button("导入 PDF") {
                    showPDFPicker = true
                }
                .buttonStyle(.bordered)
                .tint(.white)

                Button("批量导入图片") {
                    activeSheet = .photoImport
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
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

            // 拷进沙盒，异步渲染时授权还在
            let dest = FileStorage.documents.appendingPathComponent("import-temp.pdf")
            try? FileManager.default.removeItem(at: dest)

            let target: URL
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                target = dest
            } else {
                target = url
            }

            // 等文件选择器收完再弹导入界面
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                activeSheet = .pdf(target)
            }
        }
    }
}
