import SwiftUI

// MARK: - 通用小额视图

struct PaperView: View {
    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.985, blue: 0.97)
            LinearGradient(
                colors: [Color.black.opacity(0.05),
                         Color.clear,
                         Color.clear,
                         Color.black.opacity(0.05)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct SpineView: View {
    var body: some View {
        LinearGradient(
            colors: [.clear,
                     .black.opacity(0.10),
                     .black.opacity(0.22),
                     .black.opacity(0.10),
                     .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 48)
        .allowsHitTesting(false)
    }
}

struct ReaderBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(white: 0.18), Color(white: 0.08)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// 从磁盘按需加载图片的容器
struct StoredImage<Content: View>: View {
    let name: String
    let maxPixel: CGFloat
    private let content: (Image) -> Content

    @State private var image: UIImage? = nil

    init(name: String,
         maxPixel: CGFloat = 2048,
         @ViewBuilder content: @escaping (Image) -> Content) {
        self.name = name
        self.maxPixel = maxPixel
        self.content = content
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                Color.clear
            }
        }
        .task(id: name) {
            await load()
        }
    }

    private func load() async {
        if let cached = ImageLoader.cache.object(forKey: name as NSString) {
            image = cached
            return
        }
        let url = FileStorage.imageURL(named: name)
        let pixel = maxPixel
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageLoader.downsample(url: url, maxPixel: pixel)
        }.value

        if let decoded {
            ImageLoader.cache.setObject(decoded, forKey: name as NSString)
        }
        image = decoded
    }
}

// MARK: - 书架

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settingsStore: AppSettingsStore

    @State private var showNewBookAlert = false
    @State private var newBookTitle = ""
    @State private var bookToRename: Book?
    @State private var renameTitle = ""
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 24)]

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
                    Button {
                        showSettings = true
                    } label: {
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
            .alert("新建画册", isPresented: $showNewBookAlert) {
                TextField("画册名称", text: $newBookTitle)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    library.createBook(title: newBookTitle)
                }
            }
            .alert("重命名画册", isPresented: renameAlertBinding) {
                TextField("画册名称", text: $renameTitle)
                Button("取消", role: .cancel) { bookToRename = nil }
                Button("保存") {
                    if var book = bookToRename {
                        let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { book.title = trimmed }
                        library.update(book)
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
            LazyVGrid(columns: columns, spacing: 28) {
                ForEach(library.books) { book in
                    NavigationLink(value: book.id) {
                        BookCoverCell(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
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
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.95))
                .frame(height: 220)
                .overlay {
                    if let name = book.coverImageFileName {
                        StoredImage(name: name) { image in
                            image.resizable().scaledToFill()
                        }
                    } else {
                        Image(systemName: "book.closed")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)

            Text(book.title)
                .font(.headline)
                .lineLimit(1)

            Text("\(book.pages.count) 页")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
