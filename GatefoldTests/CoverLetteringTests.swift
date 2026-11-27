import SwiftUI
import Testing
import UIKit
@testable import Gatefold

/// A made cover never breaks a word in the middle, even on the phone shelf's narrowest grid cover (100 x 150 pt).
/// Lines break only where the language allows; a part shrinks, to no less than 60 %, until its words fit; a word
/// too long even then is cut whole with an ellipsis, never hyphenated or carried onto the next line.
@MainActor
struct CoverLetteringTests {
    /// The phone grid's cover (`ShelfMetrics.forWidth` under 500 pt: 100 pt wide, at 2:3).
    static let grid = CGSize(width: 100, height: 150)
    static var width: CGFloat { CoverLettering.room(onCoverWidth: grid.width) }

    private func layout(_ title: String, _ author: String, bold: Bool = false) -> (title: CoverLettering.Setting, author: CoverLettering.Setting?) {
        CoverLettering.layout(title: title, author: author, cover: Self.grid, typeSize: .large, bold: bold)
    }

    /// How wide SwiftUI draws a line of a part, set as the cover sets it, when offered all the width it likes.
    private func drawnWidth(_ line: String, _ kind: CoverLettering.Kind, scale: CGFloat, bold: Bool) throws -> CGFloat {
        let lines = CoverLines(setting: .init(lines: [line], scale: scale), font: CoverLettering.font(kind, .large, bold: bold),
                               tracking: CoverLettering.tracking(kind))
        let renderer = ImageRenderer(content: lines.foregroundStyle(.black).environment(\.legibilityWeight, bold ? .bold : .regular))
        renderer.scale = 2
        return CGFloat(try #require(renderer.cgImage).width) / 2
    }

    /// Every line of the title and the author is whole words of the text (or, for a word too long even at the floor,
    /// its start and an ellipsis), and SwiftUI draws it no wider than the cover's lettering: so it never wraps.
    @Test(arguments: [("Frankenstein", "Mary Wollstonecraft Shelley"), ("Supercalifragilistic", "Wollstonecraft"),
                      ("The Frankenstein", "Supercalifragilistic Expialidocious"),
                      ("Pneumonoultramicroscopicsilicovolcanoconiosis", "Anonymous")],
          [false, true])
    func everyLineOnAGridCoverIsWholeWordsThatFit(_ book: (String, String), _ bold: Bool) throws {
        let set = layout(book.0, book.1, bold: bold)
        let author = try #require(set.author)
        for (setting, kind, text) in [(set.title, CoverLettering.Kind.title, book.0), (author, .author, book.1.uppercased())] {
            let words = text.split(separator: " ").map(String.init)
            #expect(setting.scale >= CoverLettering.floor && setting.scale <= 1)
            for line in setting.lines {
                for word in line.split(separator: " ").map(String.init) {
                    let whole = words.contains(word) || (word.hasSuffix("…") && words.contains { $0.hasPrefix(String(word.dropLast())) })
                    #expect(whole, "\(word) on \"\(line)\" is a piece of a word of \"\(text)\"")
                }
                let drawn = try drawnWidth(line, kind, scale: setting.scale, bold: bold)
                #expect(drawn <= Self.width + 0.5, "\"\(line)\" draws \(drawn) pt wide on a \(Self.width) pt line, so it wraps")
            }
        }
    }

    /// WOLLSTONECRAFT and Frankenstein fit once shrunk a little, so all of each shows, a word to a line where needed.
    @Test func longWordsShowWholeOnceShrunk() {
        let set = layout("Frankenstein", "Mary Wollstonecraft Shelley")
        #expect(set.title.lines == ["Frankenstein"])
        #expect(set.author?.lines == ["MARY", "WOLLSTONECRAFT", "SHELLEY"])
        #expect((set.author?.scale ?? 0) < 1 && (set.author?.scale ?? 0) >= CoverLettering.floor)
    }

    /// A title of several words breaks between them, not inside the long one ("The Fran- / kenstein").
    @Test func aTitleOfSeveralWordsBreaksBetweenThem() {
        #expect(layout("The Frankenstein", "").title.lines == ["The", "Frankenstein"])
    }

    /// A word too long even at the floor is cut: its start and an ellipsis, on one line.
    @Test func aWordTooLongEvenAtTheFloorIsCutWithAnEllipsis() {
        let word = "Pneumonoultramicroscopicsilicovolcanoconiosis"
        let title = layout(word, "").title
        #expect(title.scale == CoverLettering.floor)
        #expect(title.lines.count == 1)
        let line = title.lines.first ?? ""
        #expect(line.hasSuffix("…") && word.hasPrefix(String(line.dropLast())), "the start of the word and an ellipsis: \(line)")
    }

    /// Chinese and Japanese have no spaces: a title breaks between its characters, as the language allows, and loses none.
    @Test func aTitleWithoutSpacesBreaksBetweenItsCharacters() {
        let text = "吾輩は猫である名前はまだ無い"
        let title = layout(text, "").title
        #expect(title.lines.count > 1)
        #expect(title.lines.joined() == text)
    }

    /// A title too long for the cover's height shrinks to the floor, then ends in an ellipsis on the last line that fits.
    @Test func aTitleTooLongForTheCoverStaysOnIt() throws {
        let set = layout("A Very Long Title That Goes On and On Across Many More Lines Than a Small Cover Can Hold", "Someone")
        let author = try #require(set.author)
        let byline = CoverLettering.height(author, font: CoverLettering.font(.author, .large, bold: false)) + CoverLettering.spacing
        let room = Self.grid.height - 2 * CoverLettering.padding - 2 * CoverLettering.rule - 2 * CoverLettering.spacing - byline
        #expect(CoverLettering.height(set.title, font: CoverLettering.font(.title, .large, bold: false)) <= room)
        #expect(set.title.lines.last?.hasSuffix("…") == true)
    }

    /// Ordinary titles and names keep their full size, breaking between words where they must.
    @Test func anOrdinaryBookKeepsItsFullSize() {
        let set = layout("Emma", "Jane Austen")
        #expect(set.title.scale == 1 && set.title.lines == ["Emma"])
        #expect(set.author?.scale == 1)
    }

    /// An author's name takes three lines at most, even shrunk to the floor; the last that fits ends in an ellipsis.
    @Test func anAuthorTakesThreeLinesAtMost() throws {
        let names = "Wollstonecraft Shelley Godwin Imlay Fuseli Johnson Barbauld Macaulay Inchbald Edgeworth Radcliffe"
        let author = try #require(layout("Emma", names).author)
        #expect(author.lines.count <= CoverLettering.authorLines)
        #expect(author.lines.last?.hasSuffix("…") == true)
    }

    /// Spaces at either end of a title or a name don't push its lines off-centre.
    @Test func spacesAtTheEndsAreDropped() {
        let set = layout("  Emma ", " Jane Austen ")
        #expect(set.title.lines == ["Emma"])
        #expect(set.author?.lines.joined(separator: " ") == "JANE AUSTEN")
    }

    /// A cover with no room yet (a layout's first pass, or a transition) sets nothing rather than shrinking and cutting.
    @Test func aCoverWithNoRoomSetsNothing() {
        let set = CoverLettering.layout(title: "Frankenstein", author: "Mary Shelley", cover: .zero, typeSize: .large, bold: false)
        #expect(set.title.lines.isEmpty)
        #expect(set.author == nil)
    }

    /// The lines sit as close as they did in the one Text each part used to be, title and author: one Text per line
    /// keeps the font's own line height.
    @Test func linesSitAsCloseAsInOneText() throws {
        func height(_ view: some View) throws -> CGFloat {
            let renderer = ImageRenderer(content: view.foregroundStyle(.black).environment(\.dynamicTypeSize, .large))
            renderer.scale = 2
            return CGFloat(try #require(renderer.cgImage).height) / 2
        }
        let title = ["Pride and", "Prejudice"], author = ["JANE", "AUSTEN"]
        let oldTitle = try height(Text(title.joined(separator: "\n")).font(.system(.headline, design: .serif)).multilineTextAlignment(.center))
        let newTitle = try height(CoverLines(setting: .init(lines: title, scale: 1), font: CoverLettering.font(.title, .large, bold: false),
                                             tracking: CoverLettering.tracking(.title)))
        #expect(abs(oldTitle - newTitle) <= 1, "title: one Text \(oldTitle) pt, a Text per line \(newTitle) pt")
        let oldAuthor = try height(Text(author.joined(separator: "\n")).font(.system(size: 9, weight: .medium)).tracking(1.2))
        let newAuthor = try height(CoverLines(setting: .init(lines: author, scale: 1), font: CoverLettering.font(.author, .large, bold: false),
                                              tracking: CoverLettering.tracking(.author)))
        #expect(abs(oldAuthor - newAuthor) <= 1, "author: one Text \(oldAuthor) pt, a Text per line \(newAuthor) pt")
    }

    /// With Bold Text the lettering is as heavy as SwiftUI's own fonts made it: the title's serif keeps the bold weight,
    /// and the author's name draws as wide as the old 9 pt medium did under Bold Text.
    @Test func boldTextIsAsHeavyAsBefore() throws {
        func width(_ view: some View) throws -> CGFloat {
            let renderer = ImageRenderer(content: view.foregroundStyle(.black).environment(\.dynamicTypeSize, .large).environment(\.legibilityWeight, .bold))
            renderer.scale = 2
            return CGFloat(try #require(renderer.cgImage).width) / 2
        }
        let word = "Frankenstein", name = "WOLLSTONECRAFT"
        let regular = CoverLettering.measure(word, font: CoverLettering.font(.title, .large, bold: false), tracking: 0)
        let bold = CoverLettering.measure(word, font: CoverLettering.font(.title, .large, bold: true), tracking: 0)
        #expect(bold > regular, "the bold serif \(bold) pt is no wider than the regular \(regular) pt")
        #expect(CoverLettering.font(.title, .large, bold: true).fontDescriptor.symbolicTraits.contains(.traitBold))
        let oldTitle = try width(Text(word).font(.system(.headline, design: .serif)))
        let newTitle = try drawnWidth(word, .title, scale: 1, bold: true)
        #expect(abs(oldTitle - newTitle) <= 1, "title under Bold Text: before \(oldTitle) pt, now \(newTitle) pt")
        let oldAuthor = try width(Text(name).font(.system(size: 9, weight: .medium)).tracking(1.2))
        let newAuthor = try drawnWidth(name, .author, scale: 1, bold: true)
        #expect(abs(oldAuthor - newAuthor) <= 1, "author under Bold Text: before \(oldAuthor) pt, now \(newAuthor) pt")
    }

    /// The pieces a line may break between keep every character of the text, spaces included.
    @Test(arguments: ["Mary Wollstonecraft Shelley", "Twenty-Thousand Leagues", "吾輩は猫である", "Emma"])
    func piecesKeepTheWholeText(_ text: String) {
        #expect(CoverLettering.pieces(text).joined() == text)
    }

    /// The whole cover at the grid's size, saved for the pull request's proof when GATEFOLD_PROOF_SHOTS is set.
    @Test func gridCoversForTheProof() throws {
        let books = [("Frankenstein", "Mary Wollstonecraft Shelley"), ("The Frankenstein", "Wollstonecraft"),
                     ("Supercalifragilistic", "Anonymous"), ("Pneumonoultramicroscopicsilicovolcanoconiosis", "Anonymous"),
                     ("吾輩は猫である", "夏目漱石"), ("Emma", "Jane Austen")]
        let strip = HStack(spacing: 12) {
            ForEach(books, id: \.0) { book in
                GeneratedCover(title: book.0, author: book.1).frame(width: Self.grid.width, height: Self.grid.height)
            }
        }
        .padding(12)
        .background(Color.white)
        let renderer = ImageRenderer(content: strip.environment(\.dynamicTypeSize, .large))
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        #expect(image.size.width > 6 * Self.grid.width)
        if let dir = ProcessInfo.processInfo.environment["GATEFOLD_PROOF_SHOTS"], let png = image.pngData() {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("grid-covers.png"))
        }
    }
}

