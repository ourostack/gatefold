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

    /// A small picture with something on it: a dark band across a light card.
    nonisolated private static func picture() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 45)).pngData { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 45))
            UIColor(red: 0.6, green: 0.1, blue: 0.1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 15, width: 30, height: 15))
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
    /// never a flat grey square: a dark cloth with light marks across its middle.
    @Test func aBookWithNoPictureGetsACoverMadeFromItsTitleAndAuthor() throws {
        let look = try Self.look(CatalogCover(entry: entry(), client: client))
        #expect(look.background < 0.5, "the tile is cloth, not a pale grey square (luminance \(look.background))")
        #expect(look.marks > 0.03, "its title and author show on it (\(look.marks) of its middle is lettering)")
    }

    /// The same while a picture is still on its way, or never comes: the made cover holds its place.
    @Test func aPictureStillOnItsWayShowsTheMadeCoverMeanwhile() throws {
        let look = try Self.look(CatalogCover(entry: entry(thumbnail: base.appending(path: "covers/slow.png")), client: client))
        #expect(look.background < 0.5, "the tile is cloth while the picture loads (luminance \(look.background))")
        #expect(look.marks > 0.03, "its title and author show meanwhile (\(look.marks))")
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
