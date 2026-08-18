import SwiftUI
import UIKit
import WebKit
import ReadiumNavigator
import ReadiumShared

@MainActor
final class ReadiumReaderModel: NSObject, ObservableObject, EPUBNavigatorDelegate {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var errorMessage: String?
    @Published var currentLocator: Locator?
    @Published var positions: [Locator] = []
    @Published var chapters: [ReadiumShared.Link] = []
    @Published var translation: String?
    @Published var translating = false
    private var preferences = EPUBPreferences.empty

    func load(book: Book, colorScheme: ColorScheme) async {
        guard let url = Self.epubURL(for: book) else { errorMessage = "EPUB file is unavailable."; return }
        do {
            let opened = try await ReadiumBookService.open(url: url)
            guard opened.publication.conforms(to: .epub) else { errorMessage = "This publication is not an EPUB."; return }
            let grouped = try await opened.publication.positionsByReadingOrder().get()
            positions = grouped.flatMap { $0 }
            chapters = opened.publication.manifest.tableOfContents
            preferences.theme = colorScheme == .dark ? .dark : .light
            var config = EPUBNavigatorViewController.Configuration()
            config.preferences = preferences
            let vc = try EPUBNavigatorViewController(publication: opened.publication, initialLocation: nil, config: config)
            vc.delegate = self
            navigator = vc
        } catch { errorMessage = error.localizedDescription }
    }

    func updateTheme(_ colorScheme: ColorScheme) {
        preferences.theme = colorScheme == .dark ? .dark : .light
        navigator?.submitPreferences(preferences)
    }

    var pageIndex: Int { guard let currentLocator else { return 0 }; return positions.firstIndex(of: currentLocator) ?? 0 }
    func seek(to index: Int) { guard let navigator, positions.indices.contains(index) else { return }; Task { _ = await navigator.go(to: positions[index]) } }
    func go(to chapter: ReadiumShared.Link) { guard let navigator else { return }; Task { _ = await navigator.go(to: chapter) } }
    func setFontSize(_ value: Double) { preferences.fontSize = value; navigator?.submitPreferences(preferences) }
    func translateSelection(_ selection: Selection) {
        let text = selection.locator.text.highlight?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        translating = true
        Task { @MainActor in
            if #available(iOS 26.0, *) {
                translation = await TranslationService.shared.translate(text, target: Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "ru") ?? "Не удалось перевести"
            } else { translation = "Для перевода требуется iOS 26" }
            translating = false
        }
    }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) { currentLocator = locator }
    func navigator(_ navigator: Navigator, didJumpTo locator: Locator) { currentLocator = locator }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { errorMessage = error.localizedDescription }
    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool { translateSelection(selection); return false }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
        let script = """
        (function(){
          if (window.__linguaZoomInstalled) return; window.__linguaZoomInstalled = true;
          var image = null, start = 1, startDistance = 0;
          document.addEventListener('touchstart', function(e){
            if (e.touches.length !== 2) return;
            var a=e.touches[0], b=e.touches[1], x=(a.clientX+b.clientX)/2, y=(a.clientY+b.clientY)/2;
            image = document.elementFromPoint(x,y); while(image && image.tagName !== 'IMG') image=image.parentElement;
            if (!image) return; start=parseFloat(image.dataset.linguaScale||'1'); startDistance=Math.hypot(a.clientX-b.clientX,a.clientY-b.clientY); image.style.transformOrigin='center center';
          }, {passive:true});
          document.addEventListener('touchmove', function(e){
            if (!image || e.touches.length !== 2) return;
            var a=e.touches[0], b=e.touches[1], d=Math.hypot(a.clientX-b.clientX,a.clientY-b.clientY);
            image.style.transform='scale('+Math.min(3,Math.max(1,start*d/startDistance))+')';
          }, {passive:true});
          document.addEventListener('touchend', function(){ if(image){ image.style.transform=''; image=null; } });
        })();
        """
        userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }

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
    @Environment(\.colorScheme) private var colorScheme
    @State private var showChapters = false
    @State private var showSettings = false
    @State private var fontSize = 100.0

    var body: some View {
        ZStack {
            if let navigator = model.navigator {
                ReadiumNavigatorContainer(navigator: navigator).ignoresSafeArea()
                chrome
                if let translation = model.translation {
                    VStack { Spacer(); HStack(spacing: 10) { VStack(alignment: .leading, spacing: 4) { Text("Перевод").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Text(translation).font(.body) }; Spacer(); Button { model.translation = nil; model.navigator?.clearSelection() } label: { Image(systemName: "xmark.circle.fill").font(.title3) } }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 16).padding(.bottom, 62) }
                } else if model.translating {
                    VStack { Spacer(); ProgressView("Перевод…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom, 62) }
                }
            } else if let error = model.errorMessage {
                VStack(spacing: 16) { Image(systemName: "book.closed").font(.system(size: 42)); Text("Could not open this book").font(.headline); Text(error).font(.footnote).multilineTextAlignment(.center); Button("Back") { dismiss() }.buttonStyle(.borderedProminent) }.padding(32)
            } else { ProgressView("Opening book…") }
        }
        .task(id: book.id) { await model.load(book: book, colorScheme: colorScheme) }
        .onChange(of: colorScheme) { _, newScheme in model.updateTheme(newScheme) }
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
    func makeCoordinator() -> Coordinator { Coordinator(navigator: navigator) }
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        context.coordinator.install(on: navigator)
        return navigator
    }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigator: EPUBNavigatorViewController?
        private var pan: UIPanGestureRecognizer?

        init(navigator: EPUBNavigatorViewController) { self.navigator = navigator }

        func install(on navigator: EPUBNavigatorViewController) {
            guard pan == nil else { return }
            self.navigator = navigator
            // Readium's default UIScrollView drag moves both spreads together. Disable
            // that pan and use the navigator's animated transition instead: the new
            // spread is laid out first, while a snapshot of the old spread slides away.
            DispatchQueue.main.async { [weak self, weak navigator] in
                guard let self, let navigator else { return }
                self.disablePaginationScroll(in: navigator.view)
                let gesture = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
                gesture.delegate = self
                gesture.maximumNumberOfTouches = 1
                navigator.view.addGestureRecognizer(gesture)
                self.pan = gesture
            }
        }

        private func disablePaginationScroll(in view: UIView) {
            if view is WKWebView { return }
            for child in view.subviews {
                if let scroll = child as? UIScrollView, !(child is WKWebView) {
                    scroll.isScrollEnabled = false
                    scroll.panGestureRecognizer.isEnabled = false
                }
                disablePaginationScroll(in: child)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, let navigator else { return }
            let translation = gesture.translation(in: gesture.view)
            let velocity = gesture.velocity(in: gesture.view)
            guard abs(translation.x) > 45 || abs(velocity.x) > 250 else { return }
            let forward = translation.x < 0
            Task { @MainActor in
                if forward {
                    _ = await navigator.goForward(options: .animated)
                } else {
                    _ = await navigator.goBackward(options: .animated)
                }
            }
        }
    }
}
