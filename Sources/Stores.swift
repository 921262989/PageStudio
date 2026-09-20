import SwiftUI
import PencilKit

// MARK: - 设置 + 自定义颜色

final class AppSettingsStore: ObservableObject {
    private static let settingsKey = "AppSettings.v1"
    private static let colorsKey = "SavedBrushColors.v1"
    /// 自定义颜色最多保留多少个
    private static let maxSavedColors = 12

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    /// 用户固定到笔刷栏的自定义颜色
    @Published var savedColors: [SavedBrushColor] = [] {
        didSet { saveColors() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        if let data = UserDefaults.standard.data(forKey: Self.colorsKey),
           let decoded = try? JSONDecoder().decode([SavedBrushColor].self, from: data) {
            savedColors = decoded
        }
    }

    // MARK: 自定义颜色

    /// 把颜色固定到笔刷栏。已存在则不重复添加。
    func addColor(_ color: Color) {
        let hex = color.hexString
        guard !savedColors.contains(where: { $0.hex == hex }) else { return }
        savedColors.append(SavedBrushColor(hex: hex))
        if savedColors.count > Self.maxSavedColors {
            savedColors.removeFirst(savedColors.count - Self.maxSavedColors)
        }
    }

    func removeColor(_ item: SavedBrushColor) {
        savedColors.removeAll { $0.id == item.id }
    }

    func removeColor(at offsets: IndexSet) {
        savedColors.remove(atOffsets: offsets)
    }

    // MARK: 落盘

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    private func saveColors() {
        guard let data = try? JSONEncoder().encode(savedColors) else { return }
        UserDefaults.standard.set(data, forKey: Self.colorsKey)
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
