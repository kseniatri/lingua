import SwiftUI
import UIKit
import ReadiumNavigator
import ReadiumShared

@MainActor
final class ReadiumReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var errorMessage: String?
    @Published var currentLocator: Locator?
    @Published var positions: [Locator] = []
    @Published var chapters: [ReadiumShared.Link] = []
    private var preferences = EPUBPreferences.empty

    func load(book: Book) async {
        guard let url = Self.epubURL(for: book) else { errorMessage = "EPUB file is unavailable."; return }
        do {
            let opened = try await ReadiumBookService.open(url: url)
            guard opened.publication.conforms(to: .epub) else { errorMessage = "This publication is not an EPUB."; return }
            let grouped = try await opened.publication.positionsByReadingOrder().get()
            positions = grouped.flatMap { $0 }
            chapters = opened.publication.manifest.tableOfContents
            var config = EPUBNavigatorViewController.Configuration()
            config.preferences = preferences
            let vc = try EPUBNavigatorViewController(publication: opened.publication, initialLocation: nil, config: config)
            vc.delegate = self
            navigator = vc
        } catch { errorMessage = error.localizedDescription }
    }

    var pageIndex: Int { guard let currentLocator else { return 0 }; return positions.firstIndex(of: currentLocator) ?? 0 }
    func seek(to index: Int) { guard let navigator, positions.indices.contains(index) else { return }; Task { _ = await navigator.go(to: positions[index]) } }
    func go(to chapter: ReadiumShared.Link) { guard let navigator else { return }; Task { _ = await navigator.go(to: chapter) } }
    func setFontSize(_ value: Double) { preferences.fontSize = value; navigator?.submitPreferences(preferences) }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) { currentLocator = locator }
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) { currentLocator = locator }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errorMessage = error.localizedDescription }

    private static func epubURL(for book: Book) -> URL? {
        if let path = book.importedEPUBPath, !path.isEmpty { return URL(fileURLWithPath: path) }
        if let resource = book.textResource, resource.hasSuffix(".epub") { return Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books") }
        return nil
    }
}

struct ReadiumReaderView: View {
    let book: Book
    @StateObject private var model = ReadiumReaderModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var fontSize = 100.0

    var body: some View {
        ZStack {
            if let navigator = model.navigator {
                ReadiumNavigatorContainer(navigator: navigator).ignoresSafeArea()
                chrome
            } else if let error = model.errorMessage {
                VStack(spacing: 16) { Image(systemName: "book.closed").font(.system(size: 42)); Text("Could not open this book").font(.headline); Text(error).font(.footnote).multilineTextAlignment(.center); Button("Back") { dismiss() }.buttonStyle(.borderedProminent) }.padding(32)
            } else { ProgressView("Opening book…") }
        }
        .task(id: book.id) { await model.load(book: book) }
        .navigationBarHidden(true)
        .sheet(isPresented: $showChapters) { chapterList }
        .sheet(isPresented: $showSettings) { settings }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title2.weight(.semibold)) }
                Spacer(); Text(book.title).lineLimit(1).font(.headline); Spacer()
                Button { showSettings = true } label: { Text("AA").font(.headline.weight(.bold)) }
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 12).background(.ultraThinMaterial)
            Spacer()
            HStack(spacing: 12) {
                Text("\(min(model.pageIndex + 1, max(model.positions.count, 1))) of \(model.positions.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(model.pageIndex) }, set: { model.seek(to: Int($0.rounded())) }), in: 0...Double(max(model.positions.count - 1, 1)), step: 1)
                Button { showChapters = true } label: { Image(systemName: "list.bullet").font(.headline) }
            }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 8).background(.ultraThinMaterial)
        }
    }

    private var chapterList: some View {
        NavigationStack {
            List { ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                Button(chapter.title ?? "Chapter \(index + 1)") { model.go(to: chapter); showChapters = false }
            } }.navigationTitle("Chapters").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showChapters = false } } }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form { Section("Text") { Slider(value: $fontSize, in: 80...130, step: 5) { _ in model.setFontSize(fontSize) }; Text("Размер: \(Int(fontSize))%") } }
                .navigationTitle("Reading").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
    }
}

private struct ReadiumNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
