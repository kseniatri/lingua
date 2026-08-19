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
        let version = UserDefaults.standard.integer(forKey: Self.libraryVersionKey)
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Book].self, from: data) {
            // Migrate the first MVP's placeholder books to the bundled full texts.
            books = Self.mergedWithBundledBooks(saved)
            if version < 5 {
                UserDefaults.standard.set(5, forKey: Self.libraryVersionKey)
            }
            persist()
        } else {
            books = Self.bundledBooks
            UserDefaults.standard.set(5, forKey: Self.libraryVersionKey)
            persist()
        }
    }

    private static let bundledBooks = [
        Book(id: UUID(), title: "The Wonderful Wizard of Oz", author: "L. Frank Baum", level: .a2, progress: 0, colorHex: "#D7E7E4", coverURL: "https://covers.openlibrary.org/isbn/9780451530640-L.jpg", textResource: "baum-wonderful-wizard-of-oz.epub"),
        Book(id: UUID(), title: "The Testament", author: "John Grisham", level: .c1, progress: 0, colorHex: "#DCE3EF", textResource: "the-testament-john-grisham.epub"),
        Book(id: UUID(), title: "The Bullet That Missed", author: "Richard Osman", level: .b2, progress: 0, colorHex: "#E8DDF0", textResource: "the-bullet-that-missed.epub"),
        Book(id: UUID(), title: "The Secret of Secrets", author: "Dan Brown", level: .b2, progress: 0, colorHex: "#E9E0D2", textResource: "the-secret-of-secrets.epub")
    ]

    private static func mergedWithBundledBooks(_ saved: [Book]) -> [Book] {
        var result = saved
        for bundled in bundledBooks where !result.contains(where: { $0.textResource == bundled.textResource }) {
            result.append(bundled)
        }
        return result
    }

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

    /// Stores the original EPUB without flattening it into extracted text.
    /// Readium uses this file later and resolves its spine, TOC, styles and
    /// image resources for each publication.
    func addImportedEPUB(title: String, epubURL: URL) {
        let cleanTitle = title
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "OceanofPDF.com", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents
            .appendingPathComponent("LinguaBooks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).epub")
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.copyItem(at: epubURL, to: destination)) != nil else { return }

        books.insert(
            Book(id: id,
                 title: cleanTitle.isEmpty ? "Imported book" : cleanTitle,
                 author: "Imported EPUB",
                 level: .b1,
                 progress: 0,
                 colorHex: "#DCE3EF",
                 isImported: true,
                 importedEPUBPath: destination.path),
            at: 0
        )
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
