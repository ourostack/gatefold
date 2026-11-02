import Foundation
import GatefoldCore
import ReadiumShared
import ReadiumStreamer
import UIKit

/// Opens EPUB files with Readium.
@MainActor
final class BookOpener {
    static let shared = BookOpener()

    private let httpClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var opener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        ),
        onCreatePublication: { _, container, _ in
            // Gatefold's own few lines of CSS in every chapter (see `BookStyle`).
            container = container.map { href, resource in
                guard BookStyle.applies(toPath: href.string) else { return resource }
                return resource.mapAsString { BookStyle.inject(into: $0) }
            }
        }
    )

    enum OpenError: LocalizedError {
        case unreadable(String)
        case notAnEPUB

        var errorDescription: String? {
            switch self {
            case let .unreadable(detail): "This book couldn't be opened. \(detail)"
            case .notAnEPUB: "Gatefold reads EPUB books for now."
            }
        }
    }

    func open(_ url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw OpenError.unreadable("The file is missing.") }
        // Readium 3 predates strict concurrency; its retriever and opener are only used from here.
        nonisolated(unsafe) let retriever = assetRetriever
        nonisolated(unsafe) let opener = opener
        let asset: Asset
        switch await retriever.retrieve(url: fileURL) {
        case let .success(a): asset = a
        case let .failure(error): throw OpenError.unreadable(error.localizedDescription)
        }
        switch await opener.open(asset: asset, allowUserInteraction: false, sender: nil) {
        case let .success(publication):
            guard publication.conforms(to: .epub) else { throw OpenError.notAnEPUB }
            return publication
        case let .failure(error):
            throw OpenError.unreadable(error.localizedDescription)
        }
    }

    struct Metadata {
        var title: String
        var author: String
        var cover: UIImage?
    }

    func metadata(of url: URL) async throws -> Metadata {
        nonisolated(unsafe) let publication = try await open(url)
        defer { publication.close() }
        let cover = try? await publication.cover().get()
        return Metadata(
            title: publication.metadata.title ?? url.deletingPathExtension().lastPathComponent,
            author: publication.metadata.authors.map(\.name).joined(separator: ", "),
            cover: cover
        )
    }
}
