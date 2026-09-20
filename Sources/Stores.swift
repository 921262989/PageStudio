import SwiftUI
import PencilKit

// MARK: - 设置

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

// MARK: - 书架

@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var books: [Book] = []

    init() { load() }

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    @discardableResult
    func createBook(title: String) -> Book {
        var book = Book()
        book.title = title.isEmpty ? "未命名画册" : title
        // 随机发一个纯色封面
        book.coverStyle = CoverStyle.allCases.randomElement() ?? .indigo
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
        for page in book.pages {
            if let name = page.imageFileName {
                FileStorage.deleteImage(named: name)
                ImageLoader.cache.removeObject(forKey: name as NSString)
            }
        }
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

// MARK: - 笔迹

/// 笔迹以「跨页」为单位落盘。
/// 内存里缓存；写盘延迟 0.4 秒合并，防强退丢数据又避免频繁 IO。
/// `revision` 在写盘后自增，用来通知界面「这个跨页的笔迹变了，重新烘焙」。
final class DrawingStore: ObservableObject {

    @Published private(set) var revision: Int = 0

    private var cache: [String: PKDrawing] = [:]
    private var pendingSaves: [String: DispatchWorkItem] = [:]

    private func cacheKey(bookId: UUID, spreadIndex: Int) -> String {
        "\(bookId.uuidString)_\(spreadIndex)"
    }

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

    func save(_ drawing: PKDrawing, bookId: UUID, spreadIndex: Int) {
        let key = cacheKey(bookId: bookId, spreadIndex: spreadIndex)
        cache[key] = drawing

        pendingSaves[key]?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
            try? drawing.dataRepresentation().write(to: url, options: .atomic)
            self.pendingSaves[key] = nil
            self.revision &+= 1
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func clear(bookId: UUID, spreadIndex: Int) {
        let key = cacheKey(bookId: bookId, spreadIndex: spreadIndex)
        cache[key] = PKDrawing()
        pendingSaves[key]?.cancel()
        pendingSaves[key] = nil

        let url = FileStorage.drawingURL(bookId: bookId, spreadIndex: spreadIndex)
        try? FileManager.default.removeItem(at: url)
        revision &+= 1
    }
}
