import Foundation
import GatefoldCore
import Testing
import UIKit
@testable import Gatefold

/// A reopen picture kept in one paper or window, found for a launch in another: his page, redrawn.
@MainActor
@Suite(.serialized)
struct ReopenAdaptedTests {
    private let directory = URL.cachesDirectory.appending(path: "Reopen", directoryHint: .isDirectory)

    /// A vellum page 200×300 with a band of ink across its middle, kept for `book`.
    private func keep(book: String, size: CGSize, theme: ReaderTheme, navigator: CGRect) throws {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            theme.uiBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: CGFloat(0x3A) / 255, green: CGFloat(0x2E) / 255, blue: CGFloat(0x1F) / 255, alpha: 1).setFill()
            ctx.fill(CGRect(x: navigator.minX, y: navigator.midY - 10, width: navigator.width, height: 20))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appending(path: "\(book)-\(Int(size.width))x\(Int(size.height))")
        try image.pngData()!.write(to: base.appendingPathExtension("png"))
        let meta = ReopenSnapshot.Meta(book: book, width: size.width, height: size.height, theme: theme.rawValue, savedAt: Date(),
                                       page: [navigator.minX, navigator.minY, navigator.width, navigator.height],
                                       navigator: [navigator.minX, navigator.minY, navigator.width, navigator.height], columns: 1)
        try JSONEncoder().encode(meta).write(to: base.appendingPathExtension("json"))
    }

    private func pixel(_ image: UIImage, _ point: CGPoint) -> (UInt8, UInt8, UInt8) {
        var p = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let s = image.scale
        ctx.draw(image.cgImage!, in: CGRect(x: -point.x * s, y: -(CGFloat(image.cgImage!.height) - point.y * s - 1), width: CGFloat(image.cgImage!.width), height: CGFloat(image.cgImage!.height)))
        return (p[0], p[1], p[2])
    }

    @Test func thePictureFitsItsOwnPaperAndWindowAsItIs() throws {
        let book = "adapt-\(UUID().uuidString)"
        try keep(book: book, size: CGSize(width: 200, height: 300), theme: .vellum, navigator: CGRect(x: 20, y: 40, width: 160, height: 220))
        let picture = ReopenSnapshot.load(book: book, size: CGSize(width: 200, height: 300), theme: .vellum)
        #expect(picture != nil)
        #expect(picture?.adapted == false)
    }

    @Test func anotherPaperRecoloursHisPage() throws {
        let book = "adapt-\(UUID().uuidString)"
        try keep(book: book, size: CGSize(width: 200, height: 300), theme: .vellum, navigator: CGRect(x: 20, y: 40, width: 160, height: 220))
        let picture = try #require(ReopenSnapshot.load(book: book, size: CGSize(width: 200, height: 300), theme: .midnight))
        #expect(picture.adapted)
        // Paper is midnight's black; the band of ink is midnight's ink.
        let paper = pixel(picture.image, CGPoint(x: 5, y: 5))
        #expect(paper.0 < 8 && paper.1 < 8 && paper.2 < 8)
        let ink = pixel(picture.image, CGPoint(x: 100, y: 150))
        #expect(abs(Int(ink.0) - 0xC9) < 6 && abs(Int(ink.1) - 0xC4) < 6, "ink \(ink) paper \(paper)")
    }

    @Test func anotherWindowSetsHisPageIntoIt() throws {
        let book = "adapt-\(UUID().uuidString)"
        try keep(book: book, size: CGSize(width: 200, height: 300), theme: .vellum, navigator: CGRect(x: 20, y: 40, width: 160, height: 220))
        let picture = try #require(ReopenSnapshot.load(book: book, size: CGSize(width: 300, height: 200), theme: .vellum))
        #expect(picture.adapted)
        #expect(picture.image.size == CGSize(width: 300, height: 200))
        // His band of ink is still across the middle of the page, now centred in the wider window.
        let ink = pixel(picture.image, CGPoint(x: 150, y: 40 + (200 - 40 - 40) / 2.0))
        #expect(ink.0 < 0x80, "ink \(ink) at 150,100 of \(picture.image.size) scale \(picture.image.scale); 150,40 \(pixel(picture.image, CGPoint(x: 150, y: 45))) 150,150 \(pixel(picture.image, CGPoint(x: 150, y: 150)))")
    }
}
