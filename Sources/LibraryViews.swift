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

    private let columns = [GridItem(.adaptive(minimum: 152, maximum: 220), spacing: 26)]

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    bookGrid
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
                Button("创建") { library.createBook(title: newBookTitle) }
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
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { bookToRename != nil },
            set: { if !$0 { bookToRename = nil } }
        )
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(library.books) { book in
                    NavigationLink(value: book.id) {
                        BookCoverCell(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            coverEditingBook = book
                        } label: {
                            Label("更换封面", systemImage: "paintpalette")
                        }
                        Button {
                            bookToRename = book
                            renameTitle = book.title
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            library.delete(book)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(24)
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
        }
    }
}

// MARK: - 书架格子

struct BookCoverCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotebookCoverView(book: book)

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
