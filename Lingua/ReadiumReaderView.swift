import SwiftUI
import UIKit
import ReadiumNavigator
import ReadiumShared

@MainActor
final class ReadiumReaderModel: ObservableObject {
    @Published var navigator: EPUBNavigatorViewController?
    @Published var errorMessage: String?

    func load(book: Book) async {
        guard let url = ReadiumReaderModel.epubURL(for: book) else {
            errorMessage = "EPUB file is unavailable."
            return
        }
        do {
            let opened = try await ReadiumBookService.open(url: url)
            guard opened.publication.conforms(to: .epub) else {
                errorMessage = "This publication is not an EPUB."
                return
            }
            navigator = try EPUBNavigatorViewController(
                publication: opened.publication,
                initialLocation: nil,
                config: .init()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func epubURL(for book: Book) -> URL? {
        if let path = book.importedEPUBPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let resource = book.textResource, resource.hasSuffix(".epub") {
            return Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: "Books")
        }
        return nil
    }
}

struct ReadiumReaderView: View {
    let book: Book
    @StateObject private var model = ReadiumReaderModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let navigator = model.navigator {
                ReadiumNavigatorContainer(navigator: navigator)
                    .ignoresSafeArea()
            } else if let error = model.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 42))
                    Text("Could not open this book")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Back") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
            } else {
                ProgressView("Opening book…")
            }
        }
        .task(id: book.id) {
            await model.load(book: book)
        }
        .navigationBarHidden(true)
    }
}

private struct ReadiumNavigatorContainer: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}
