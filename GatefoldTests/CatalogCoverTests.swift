import Foundation
import GatefoldCore
import SwiftUI
import Testing
import UIKit
@testable import Gatefold

/// A catalog row never shows a blank tile: its book's picture from the catalog, fetched through the catalog's own
/// client (so a catalog behind a password gets its covers too), or else a cover made from its title and author.
@MainActor @Suite struct CatalogCoverTests {
    private let host = "covers-\(UUID().uuidString.prefix(8).lowercased()).test"
    private var base: URL { URL(string: "https://\(host)")! }
    private var client: CatalogClient { CatalogClient(session: StandInServer.session) }

    private func entry(thumbnail: URL? = nil, cover: URL? = nil) -> CatalogEntry {
        CatalogEntry(id: "urn:test:frankenstein", title: "Frankenstein", author: "Mary Shelley", summary: nil, navigation: nil,
                     acquisitions: [], cover: cover, thumbnail: thumbnail)
    }

    /// A small picture with something on it: a thin dark band across the top of a light card, clear of the middle that look() reads.
    nonisolated private static func picture(width: CGFloat = 30, height: CGFloat = 45) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor(red: 0.6, green: 0.1, blue: 0.1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 6))
        }
    }

    @Test func aCoverIsFetchedThroughTheCatalogsOwnClient() async throws {
        let png = Self.picture()
        StandInServer.answer(host) { request in
            request.url?.path() == "/covers/1.png" ? (200, png) : (404, Data())
        }
        let image = try #require(await client.cover(at: base.appending(path: "covers/1.png")))
        #expect(image.size.width * image.scale == 30)
        #expect(image.size.height * image.scale == 45)
    }

    /// calibre-web links its full-size cover as the thumbnail: it's decoded no bigger than the row needs.
    @Test func aFullSizeCoverIsDecodedSmall() async throws {
        let png = Self.picture(width: 1400, height: 2100)
        StandInServer.answer(host) { request in
            request.url?.path() == "/covers/big.png" ? (200, png) : (404, Data())
        }
        let image = try #require(await client.cover(at: base.appending(path: "covers/big.png")))
        #expect(image.size.width * image.scale <= 300)
        #expect(image.size.height * image.scale <= 450)
        #expect(image.size.height * image.scale >= 440, "shrunk to fit, not to nothing")
    }

    @Test func aPageWhereTheCoverShouldBeGivesNoCover() async {
        StandInServer.answer(host) { request in
            switch request.url?.path() {
            case "/covers/page.png": (200, Data("<!doctype html><html><body>Sign in</body></html>".utf8))
            case "/covers/locked.png": (401, Data())
            default: (404, Data())
            }
        }
        #expect(await client.cover(at: base.appending(path: "covers/page.png")) == nil)
        #expect(await client.cover(at: base.appending(path: "covers/locked.png")) == nil)
        #expect(await client.cover(at: base.appending(path: "covers/missing.png")) == nil)
    }

    /// With no picture at all, the tile is a made cover (the shelf's cloth, its title and author stamped in white),
    /// never a flat grey square: a dark cloth with light marks across its middle. A flat tile has no marks at all; the
    /// made cover, drawn at 150 pt and shrunk into a 40 pt book, has about 3 % of its middle in lettering.
    @Test func aBookWithNoPictureGetsACoverMadeFromItsTitleAndAuthor() throws {
        let look = try Self.look(CatalogCover(entry: entry(), client: client).frame(width: 64, height: 64))
        #expect(look.background < 0.5, "the tile is cloth, not a pale grey square (luminance \(look.background))")
        #expect(look.marks > 0.01, "its title and author show on it (\(look.marks) of its middle is lettering)")
    }

    /// A book whose picture hasn't been fetched (still on its way, or never coming) shows the made cover meanwhile.
    @Test func aPictureNotYetFetchedShowsTheMadeCoverMeanwhile() throws {
        let look = try Self.look(CatalogCover(entry: entry(thumbnail: base.appending(path: "covers/slow.png")), client: client)
            .frame(width: 64, height: 64))
        #expect(look.background < 0.5, "the tile is cloth while the picture loads (luminance \(look.background))")
        #expect(look.marks > 0.01, "its title and author show meanwhile (\(look.marks))")
    }

    /// Once the picture is there, it's what shows: the light card with its band, not the cloth.
    @Test func aFetchedPictureCoversTheMadeOne() throws {
        let picture = try #require(UIImage(data: Self.picture()))
        let look = try Self.look(CatalogCover(entry: entry(thumbnail: base.appending(path: "covers/1.png")), client: client, picture: picture)
            .frame(width: 64, height: 64))
        #expect(look.background > 0.8, "the picture's light card shows (luminance \(look.background))")
    }

    @Test func aCatalogPagesCoversAreReportedAsCountsOnly() {
        let book = CatalogAcquisition(url: base.appending(path: "1.epub"), mediaType: "application/epub+zip", rel: "http://opds-spec.org/acquisition", length: nil, title: nil)
        func entry(_ id: String, picture: Bool, book isBook: Bool = true) -> CatalogEntry {
            CatalogEntry(id: id, title: "Title \(id)", author: "Someone", summary: nil, navigation: isBook ? nil : base, acquisitions: isBook ? [book] : [],
                         cover: nil, thumbnail: picture ? base.appending(path: "\(id).png") : nil)
        }
        let page = [entry("a", picture: true), entry("b", picture: false), entry("c", picture: false, book: false)]
        #expect(GatefoldTelemetry.coverProperties(page) == ["books": .int(2), "with_picture": .int(1)])
        #expect(GatefoldTelemetry.coverProperties([entry("c", picture: false, book: false)]) == nil)
    }

    /// Renders the view and reads its middle: the commonest luminance there, and the share of pixels far from it.
    private static func look(_ view: some View) throws -> (background: Double, marks: Double) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var levels = [Int](repeating: 0, count: 11)
        var middle: [Double] = []
        for y in (height / 5)..<(height * 4 / 5) {
            for x in (width / 5)..<(width * 4 / 5) {
                let i = (y * width + x) * 4
                let l = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
                middle.append(l)
                levels[Int((l * 10).rounded())] += 1
            }
        }
        let background = Double(levels.indices.max { levels[$0] < levels[$1] } ?? 0) / 10
        let marks = Double(middle.filter { abs($0 - background) > 0.3 }.count) / Double(max(middle.count, 1))
        return (background, marks)
    }
}
