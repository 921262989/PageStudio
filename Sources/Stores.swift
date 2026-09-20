import SwiftUI

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
        for page in book.pages {
            if let name = page.imageFileName {
                FileStorage.deleteImage(named: name)
                ImageLoader.cache.removeObject(forKey: name as NSString)
            }
        }
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
