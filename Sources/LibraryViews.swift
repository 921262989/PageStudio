import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @State private var showNewBookAlert = false
    @State private var newBookTitle = ""
    @State private var bookToRename: Book?
    @State private var renameTitle = ""
    @State private var showSettings = false
    @State private var coverEditingBook: Book?
    @State private var carouselIndex = 0
    @State private var openBookID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    carouselShelf
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
                    Button {
                        newBookTitle = ""
                        showNewBookAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BookReaderView(bookID: id)
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
            .alert("新建画册", isPresented: $showNewBookAlert) {
                TextField("画册名称", text: $newBookTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let created = library.createBook(title: newBookTitle)
                    carouselIndex = 0
                    _ = created
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

    private var carouselShelf: some View {
        VStack(spacing: 0) {
            BookCarousel(books: library.books,
                         index: $carouselIndex,
                         onOpen: { book in
                             openBookID = book.id
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
        }
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { openBookID != nil },
                    set: { if !$0 { openBookID = nil } }
                ),
                destination: {
                    if let id = openBookID {
                        BookReaderView(bookID: id)
                    }
                },
                label: { EmptyView() }
            )
            .opacity(0)
            .frame(width: 0, height: 0)
        )
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
        }
    }
}

// MARK: - 书架格子（列表样式，留给以后备用）

struct BookCoverCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                NotebookCoverView(book: book, width: geo.size.width)
            }
            .aspectRatio(1.0 / 1.38, contentMode: .fit)

            Text(book.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)

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
    }
}
