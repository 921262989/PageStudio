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
        // ⚠️ 所有呈现类修饰符都挂在 NavigationStack 最外层，
        //    挂在里层（Group 上）会导致 fileImporter 静默失败。
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

    /// 菜单项点击后延迟一点点再触发，避免和菜单收起动画打架
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
                             path.append(book.id)
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

    // MARK: - PDF 选择

    private func handlePDFSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            break

        case .success(let urls):
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // 拷进沙盒。文件选择器给的是临时授权，异步渲染时可能已失效。
            let dest = FileStorage.documents.appendingPathComponent("import-temp.pdf")
            try? FileManager.default.removeItem(at: dest)

            let target: URL
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                target = dest
            } else {
                target = url
            }

            // 再延迟一下，避免和文件选择器的收起动画打架
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pdfFileRef = PDFFileRef(url: target)
            }
        }
    }
}
