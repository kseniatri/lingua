import Foundation

enum EnglishLevel: String, CaseIterable, Codable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"
}

struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var level: EnglishLevel
    var progress: Double
    var colorHex: String
    var isImported: Bool = false
    var coverURL: String? = nil
    var textResource: String? = nil
    var importedTextPath: String? = nil
    var importedEPUBPath: String? = nil
}

final class LibraryStore: ObservableObject {
    @Published var books: [Book]

    private static let storageKey = "lingua.library.books"
    private static let libraryVersionKey = "lingua.library.version"

    init() {
        if UserDefaults.standard.integer(forKey: Self.libraryVersionKey) < 4 {
            books = Self.bundledBooks
            UserDefaults.standard.set(4, forKey: Self.libraryVersionKey)
            persist()
        } else if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Book].self, from: data) {
            // Migrate the first MVP's placeholder books to the bundled full texts.
            let imported = saved.filter { $0.isImported }
            books = saved.contains(where: { $0.textResource != nil }) ? saved : Self.bundledBooks + imported
            persist()
        } else {
            books = Self.bundledBooks
            persist()
        }
    }

    private static let bundledBooks = [
        Book(id: UUID(), title: "The Wonderful Wizard of Oz", author: "L. Frank Baum", level: .a2, progress: 0, colorHex: "#D7E7E4", coverURL: "https://covers.openlibrary.org/isbn/9780451530640-L.jpg", textResource: "baum-wonderful-wizard-of-oz.epub")
    ]

    func addImportedBook(title: String, textURL: URL, epubURL: URL) {
        let cleanTitle = title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "OceanofPDF.com", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent("LinguaBooks", isDirectory: true).appendingPathComponent("\(id.uuidString).epub")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: epubURL, to: destination)
        books.insert(Book(id: id, title: cleanTitle.isEmpty ? "Imported book" : cleanTitle, author: "Imported EPUB", level: .b1, progress: 0, colorHex: "#DCE3EF", isImported: true, importedTextPath: textURL.path, importedEPUBPath: destination.path), at: 0)
        persist()
    }

    func remove(_ book: Book) {
        books.removeAll { $0.id == book.id }
        persist()
    }

    func updateProgress(for book: Book, value: Double) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].progress = min(max(value, 0), 1)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
