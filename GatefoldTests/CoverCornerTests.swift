import GatefoldCore
import OuroHX
import SwiftUI
import Testing
import UIKit
@testable import Gatefold

/// Every cover, made or real, on the shelf and in a catalog row, is clipped to the cover squircle (`CoverShape`): never
/// a square corner, never another radius. Read from the drawn pixels at each corner, so a surface that forgets the clip
/// or clips to something else fails.
@MainActor @Suite struct CoverCornerTests {
    /// Points this far either side of the shape's edge are left out: anti-aliasing makes them part-covered.
    private static let edge: CGFloat = 0.75
    private static let scale: CGFloat = 3

    private static let book = LibraryBook(id: "corner-1", title: "Frankenstein", author: "Mary Shelley", origin: .imported, added: Date())

    /// A small picture, opaque edge to edge, standing in for a real cover.
    private static func picture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 90), format: format).image { context in
            UIColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 90))
        }
    }

    private static func entry(thumbnail: URL?) -> CatalogEntry {
        CatalogEntry(id: "urn:test:corner", title: "Frankenstein", author: "Mary Shelley", summary: nil, navigation: nil,
                     acquisitions: [], cover: nil, thumbnail: thumbnail)
    }

    /// The drawn view's alpha, one byte per pixel, row by row.
    private func alpha(_ view: some View, size: CGSize) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The context's rows run top down in memory, as the image's do.
        return (stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }, width, height)
    }

    /// The corners of a cover drawn in `cover` (in the view's points) where the pixels don't follow `CoverShape`: a pixel
    /// inside the shape must be drawn, one outside it (in the corner the shape cuts away) must not.
    private func misfits(_ view: some View, size: CGSize, cover: CGRect) throws -> [String] {
        let (bytes, width, height) = try alpha(view, size: size)
        let path = CoverShape().path(in: cover)
        var misfits: [String] = []
        let reach: CGFloat = 2 * CoverShape.foreEdge
        let corners = [("top leading", CGPoint(x: cover.minX, y: cover.minY)), ("top trailing", CGPoint(x: cover.maxX - reach, y: cover.minY)),
                       ("bottom leading", CGPoint(x: cover.minX, y: cover.maxY - reach)),
                       ("bottom trailing", CGPoint(x: cover.maxX - reach, y: cover.maxY - reach))]
        for (name, origin) in corners {
            var inside = 0, outside = 0, wrong = 0
            for row in 0..<Int(reach * Self.scale) {
                for column in 0..<Int(reach * Self.scale) {
                    let point = CGPoint(x: origin.x + (CGFloat(column) + 0.5) / Self.scale, y: origin.y + (CGFloat(row) + 0.5) / Self.scale)
                    let near = [CGPoint(x: -Self.edge, y: 0), CGPoint(x: Self.edge, y: 0), CGPoint(x: 0, y: -Self.edge), CGPoint(x: 0, y: Self.edge)]
                        .map { path.contains(CGPoint(x: point.x + $0.x, y: point.y + $0.y)) }
                    let within = path.contains(point)
                    guard near.allSatisfy({ $0 == within }) else { continue }
                    let x = Int(point.x * Self.scale), y = Int(point.y * Self.scale)
                    guard x >= 0, y >= 0, x < width, y < height else { continue }
                    let drawn = Double(bytes[y * width + x]) / 255
                    if within { inside += 1; if drawn < 0.9 { wrong += 1 } } else { outside += 1; if drawn > 0.5 { wrong += 1 } }
                }
            }
            if outside == 0 || inside == 0 || wrong > 0 {
                misfits.append("\(name): \(wrong) pixels off the cover squircle (\(inside) inside, \(outside) cut away)")
            }
        }
        return misfits
    }

    /// The shelf's cover, made (no picture) or real, at the phone grid's size and a larger shelf's.
    @Test(arguments: [false, true], [CGSize(width: 100, height: 150), CGSize(width: 180, height: 270)])
    func aShelfCoverIsTheCoverSquircle(_ real: Bool, _ size: CGSize) throws {
        let view = CoverView(book: Self.book, image: real ? Self.picture() : nil, coverless: !real)
        let misfits = try misfits(view, size: size, cover: CGRect(origin: .zero, size: size))
        #expect(misfits.isEmpty, "\(real ? "real" : "made") cover at \(size): \(misfits)")
    }

    /// A catalog row's cover, made or real, in Ouro's row as the catalog draws it: the medium media tile at the Large
    /// text size, and the wide tile Ouro lifts above the words at the accessibility sizes.
    @Test(arguments: [false, true], [false, true])
    func aCatalogRowCoverIsTheCoverSquircle(_ real: Bool, _ lifted: Bool) throws {
        let entry = Self.entry(thumbnail: real ? URL(string: "https://covers.test/frankenstein.png") : nil)
        let tileShape = RoundedRectangle(cornerRadius: OuroTheme.gatefold.radius(OuroItemMetrics.mediaRadius(.md)), style: .continuous)
        let side = OuroItemMetrics.mediaSide(.md)
        let tile = lifted ? CGSize(width: 320, height: 240) : CGSize(width: side, height: side)
        let view = CatalogCover(entry: entry, picture: real ? Self.picture() : nil)
            .frame(width: tile.width, height: tile.height)
            .clipShape(tileShape)
        // Where CatalogCover puts the book in its tile.
        let height = tile.height - CatalogCover.inset
        let width = min((height * 2 / 3).rounded(), tile.width)
        let cover = CGRect(x: (tile.width - width) / 2, y: (tile.height - height) / 2, width: width, height: height)
        let misfits = try misfits(view, size: tile, cover: cover)
        #expect(misfits.isEmpty, "\(real ? "real" : "made") catalog cover, \(lifted ? "lifted" : "in the row"): \(misfits)")
    }
}
