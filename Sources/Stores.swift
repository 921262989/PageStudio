import SwiftUI
import PencilKit

// MARK: - 设置 + 自定义颜色 + 笔刷

final class AppSettingsStore: ObservableObject {
    private static let settingsKey = "AppSettings.v1"
    private static let colorsKey = "SavedBrushColors.v1"
    private static let brushKey = "BrushPreset.v1"
    private static let maxSavedColors = 12

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }

    @Published var savedColors: [SavedBrushColor] = [] {
        didSet { saveColors() }
    }

    @Published var brushPreset: BrushPreset = BrushPreset() {
        didSet { saveBrushPreset() }
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

        if let data = UserDefaults.standard.data(forKey: Self.brushKey),
           let decoded = try? JSONDecoder().decode(BrushPreset.self, from: data) {
            brushPreset = decoded
        }
    }

    // MARK: 自定义颜色

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

    // MARK: 笔刷参数

    func brushSettings(for kind: PenKind) -> BrushSettings {
        brushPreset.settings(for: kind)
    }

    func updateBrush(_ value: BrushSettings, for kind: PenKind) {
        var preset = brushPreset
        preset.update(value, for: kind)
        brushPreset = preset
    }

    func resetBrush(_ kind: PenKind) {
        updateBrush(BrushSettings.standard(for: kind), for: kind)
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

    private func saveBrushPreset() {
        guard let data = try? JSONEncoder().encode(brushPreset) else { return }
        UserDefaults.standard.set(data, forKey: Self.brushKey)
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

    /// 复制一本画册：页面图片、封面图、笔迹、封面自选颜色、内页样式全都各来一份
    @discardableResult
    func duplicate(_ book: Book) -> Book {
        var copy = book
        copy.id = UUID()
        copy.title = book.title + " 副本"

        // 页面图片：复制成新文件，避免两本共用同一张图（删一本会连累另一本）
        var newPages: [Page] = []
        for page in book.pages {
            var p = page
            if let name = page.imageFileName {
                let src = FileStorage.imageURL(named: name)
                if let data = try? Data(contentsOf: src) {
                    let ext = (name as NSString).pathExtension
                    if let newName = try? FileStorage.saveImageData(
                        data,
                        preferredExtension: ext.isEmpty ? "jpg" : ext
                    ) {
                        p.imageFileName = newName
                    }
                }
            }
            newPages.append(p)
        }
        copy.pages = newPages

        // 封面图
        if let cover = book.customCoverImage {
            let src = FileStorage.coverURL(named: cover)
            if let data = try? Data(contentsOf: src) {
                let ext = (cover as NSString).pathExtension
                if let newName = try? FileStorage.saveCoverData(
                    data,
                    preferredExtension: ext.isEmpty ? "jpg" : ext
                ) {
                    copy.customCoverImage = newName
                }
            }
        }

        // 封面自选颜色
        if let hex = CoverColorStore.hex(for: book.id) {
            CoverColorStore.setHex(hex, for: copy.id)
        }

        // 内页样式
        if let ruleData = UserDefaults.standard.data(forKey: PageRuleStore.key(for: book.id)) {
            UserDefaults.standard.set(ruleData, forKey: PageRuleStore.key(for: copy.id))
        }

        // 笔迹目录
        let srcDir = FileStorage.drawingsDirectory
            .appendingPathComponent(book.id.uuidString, isDirectory: true)
        let dstDir = FileStorage.drawingsDirectory
            .appendingPathComponent(copy.id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: srcDir.path) {
            try? FileManager.default.copyItem(at: srcDir, to: dstDir)
        }

        books.insert(copy, at: 0)
        save()
        return copy
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

        // 清掉这本书的附加设置
        CoverColorStore.setHex(nil, for: book.id)
        BookLock.setPassword(nil, for: book.id)
        UserDefaults.standard.removeObject(forKey: PageRuleStore.key(for: book.id))

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

// MARK: - 旧版单层笔迹（保留兼容）

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
