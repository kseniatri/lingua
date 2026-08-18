import Foundation
import ReadiumShared
import ReadiumStreamer

/// The single entry point for opening publications with Readium.
///
/// Keeping this separate from the current reader lets us validate EPUB files
/// with the production parser before replacing the custom pagination UI.
enum ReadiumBookService {
    struct OpenedBook {
        let publication: Publication
        let format: Format
    }

    static func open(url: URL) async throws -> OpenedBook {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        guard let fileURL = FileURL(url: url) else {
            throw URLError(.badURL)
        }
        let asset = try await assetRetriever
            .retrieve(url: fileURL)
            .get()
        let publication = try await opener
            .open(asset: asset, allowUserInteraction: false)
            .get()

        return OpenedBook(publication: publication, format: asset.format)
    }
}
