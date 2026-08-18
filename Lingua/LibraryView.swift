import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showingImporter = false
    @State private var selectedBook: Book?
    @State private var bookToDelete: Book?
    @State private var importProgress: Double?
    @State private var importingTitle = ""

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(library.books) { book in
                            BookCard(book: book) { selectedBook = book } onLongPress: { bookToDelete = book }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .bottomTrailing) {
                Button { showingImporter = true } label: {
                    if let importProgress {
                        ProgressView(value: importProgress)
                            .tint(.white)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.teal, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .padding(.trailing, 22)
                .padding(.bottom, 28)
            }
            .navigationDestination(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .confirmationDialog("Delete this book?", isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } })) {
                Button("Delete", role: .destructive) { if let book = bookToDelete { library.remove(book) }; bookToDelete = nil }
                Button("Cancel", role: .cancel) { bookToDelete = nil }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]) { result in
                if case .success(let url) = result {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    let title = url.deletingPathExtension().lastPathComponent
                    importingTitle = title
                    importProgress = 0
                    Task {
                        let textURL = await Task.detached(priority: .userInitiated) {
                            try? EPUBImporter.extractText(from: url) { value in
                                Task { @MainActor in importProgress = value }
                            }
                        }.value
                        if let textURL {
                            await MainActor.run {
                                library.addImportedBook(title: title, textURL: textURL, epubURL: url)
                                importProgress = nil
                            }
                        } else {
                            await MainActor.run { importProgress = nil }
                        }
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }
        }
    }

    private var header: some View {
        Text("My library")
            .font(.system(size: 34, weight: .bold, design: .serif))
    }

    private var addCard: some View {
        Button { showingImporter = true } label: {
            VStack(spacing: 12) {
                if let importProgress {
                    ProgressView(value: importProgress)
                        .tint(.teal)
                        .padding(.horizontal, 28)
                    Text("Processing book").font(.headline)
                    Text("\(Int(importProgress * 100))% complete")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(.teal)
                    Text("Import EPUB").font(.headline)
                    Text("Bring your own book").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 218)
            .background(.background, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.teal.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6])))
        }.buttonStyle(.plain)
    }
}

struct BookCard: View {
    let book: Book
    let action: () -> Void
    let onLongPress: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    CoverView(book: book)
                    Text(book.level.rawValue)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.teal, in: Capsule()).padding(10)
                }
                ProgressView(value: book.progress).tint(.teal)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onLongPress()
            } label: {
                Label("Delete book", systemImage: "trash")
            }
        }
    }
}

struct CoverView: View {
    let book: Book
    @State private var extractedCover: UIImage?
    var body: some View {
        ZStack {
            if let extractedCover {
                Image(uiImage: extractedCover).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let coverURL = book.coverURL, let url = URL(string: coverURL) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                    }
                }
            } else {
                VStack(spacing: 7) {
                    Text(book.title.uppercased())
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .multilineTextAlignment(.center).lineLimit(3)
                    Rectangle().frame(width: 34, height: 1).opacity(0.45)
                    Text(book.author).font(.system(size: 9, design: .serif)).multilineTextAlignment(.center).lineLimit(2)
                }.foregroundStyle(.black.opacity(0.72)).padding(18)
            }
        }
        .frame(height: 218)
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
        .task {
            guard extractedCover == nil else { return }
            let url: URL?
            if let path = book.importedEPUBPath { url = URL(fileURLWithPath: path) }
            else if let resource = book.textResource, resource.hasSuffix(".epub") { url = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books") }
            else { url = nil }
            guard let url else { return }
            if let imageURL = try? await Task.detached(priority: .utility) { try? EPUBImporter.extractFirstImage(from: url) }.value,
               let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) {
                extractedCover = image
            }
        }
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}
extension UIColor {
    convenience init(hex: String) {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
