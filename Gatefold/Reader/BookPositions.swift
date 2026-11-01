import Foundation
import GatefoldCloud
import ReadiumShared

/// Builds the `PositionMapper` for an open book from the EPUB's own package and XHTML, so the place
/// we send PocketBook Cloud is the same exact CFI its InkPad and web reader write.
enum BookPositions {
    static func mapper(for publication: Publication) async -> PositionMapper? {
        let source = PublicationResources(publication: publication)
        guard let container = try? await source.data("META-INF/container.xml"),
              let opfPath = packagePath(inContainerXML: container),
              let opf = try? await source.data(opfPath),
              let spine = try? SpineMap(opf: opf, opfPath: opfPath) else {
            readerLog.error("no package document; places sync as percentages")
            return nil
        }
        return PositionMapper(spine: spine) { href in try await source.data(href) }
    }

    /// `full-path` of the first rootfile in `META-INF/container.xml`.
    static func packagePath(inContainerXML data: Data) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        guard let range = xml.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = xml[range]
        guard let open = match.firstIndex(of: "\"") else { return nil }
        return String(match[match.index(after: open)...].dropLast())
    }
}

/// Reads a resource's bytes by container path. Readium's publication is read-only once open and its
/// resources are safe to read from any task.
private struct PublicationResources: @unchecked Sendable {
    let publication: Publication

    struct Missing: Error {}

    func data(_ path: String) async throws -> Data {
        guard let url = AnyURL(string: path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path),
              let resource = publication.get(url) else { throw Missing() }
        return try await resource.read().get()
    }
}
