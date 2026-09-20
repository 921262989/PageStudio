import SwiftUI
import PencilKit

// MARK: - 设置存储

final class AppSettingsStore: ObservableObject {
    private static let storageKey = "AppSettings.v1"

    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

// MARK: - 书架数据源

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var books: [Book] = []

    init() {
        load()
    }

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    @discardableResult
    func createBook(title: String) -> Book {
        var book = Book(title: title.isEmpty ? "未命名画册" : title)
        book.pages = [Page.blank(), Page.blank()]
        books.insert(book, at: 0)
        save()
        return book
    }

    func update(_ book: Book) {
        var updated = book
        updated.updatedAt = Date()
        guard let index = books.firstIndex(where: { $0.id == updated.id }) else { return }
        books[index] = updated
        save()
    }

    func delete(_ book: Book) {
        // 清理图片文件
        for page in book.pages {
            if let name = page.imageFileName {
                FileStorage.deleteImage(named: name)
                ImageLoader.cache.removeObject(forKey: name as NSString)
            }
        }
        // 清理笔迹目录
        FileStorage.deleteDrawings(bookId: book.id)

        books.removeAll { $0.id == book.id }
        save()
    }

    private func load() {
        FileStorage.ensure(FileStorage.documents)
        guard let data = try? Data(contentsOf: FileStorage.libraryFile) else {
            books = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        books = (try? decoder.decode([Book].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(books) else { return }
        try? data.write(to: FileStorage.libraryFile, options: .atomic)
    }
}

// MARK: - 笔迹存储

/// 笔迹以「跨页」为单位落盘。
/// 内存里缓存已加载的 PKDrawing；写盘延迟 0.5 秒合并，防止强退丢数据的同时避免频繁 IO。
final class DrawingStore: ObservableObject {

    private var cache: [String: PKDrawing] = [:]
    private var pendingSaves: [String: DispatchWorkItem] = [:]

    private func cacheKey(bookId: UUID, spreadIndex: Int) -> String {
        "\(bookId.uuidString)_\(spreadIndex)"
    }

    /// 读取某跨页的笔迹。没有就返回空画布。
    func load(bookId: UUID, spreadIndex: Int) -> PKDrawing {
        let key = cacheKey(bookId: bookId, spreadIndex: spreadIndex)
        if let cached = cache[key] { return cached }

        let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
        let drawing: PKDrawing
        if let data = try? Data(contentsOf: url),
           let loaded = try? PKDrawing(data: data) {
            drawing = loaded
        } else {
            drawing = PKDrawing()
        }
        cache[key] = drawing
        return drawing
    }

    /// 保存笔迹。内存立即更新，写盘延迟 0.5 秒。
    func save(_ drawing: PKDrawing, bookId: UUID, spreadIndex: Int) {
        let key = cacheKey(bookId: bookId, spreadIndex: spreadIndex)
        cache[key] = drawing

        pendingSaves[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
            let data = drawing.dataRepresentation()
            try? data.write(to: url, options: .atomic)
            self.pendingSaves[key] = nil
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 立即把所有待写盘的内容落盘（比如 App 退到后台时）
    func flushAll(bookId: UUID) {
        for (key, work) in pendingSaves where key.hasPrefix(bookId.uuidString) {
            work.cancel()
            work.perform()
        }
    }

    /// 清空某跨页的笔迹
    func clear(bookId: UUID, spreadIndex: Int) {
        let key = cacheKey(bookId: bookId, spreadIndex: spreadIndex)
        cache[key] = PKDrawing()
        pendingSaves[key]?.cancel()
        pendingSaves[key] = nil

        let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
        try? FileManager.default.removeItem(at: url)
    }
}
