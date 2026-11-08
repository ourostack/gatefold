import Foundation
import ReadiumShared
import Testing
@testable import Gatefold

/// A curl that springs back leaves him on the page he started from. Stepping back a page across a chapter's
/// start lands at the start of the chapter before, not its last page (the Duo, #110 walk run 42512799887: a
/// drag let go on h-4's last page sprang back and the place became h-4 @0.00000).
@MainActor struct CurlSpringBackTests {
    /// Two chapters of five pages; stepping back from a chapter's first page lands at the previous chapter's
    /// first page, as Readium's did.
    @MainActor final class Book {
        var chapter = 0, page = 0
        var location: Locator { Self.locator(chapter, page) }

        static func locator(_ chapter: Int, _ page: Int) -> Locator {
            Locator(href: AnyURL(string: "h-\(chapter + 4).htm.html")!, mediaType: .xhtml,
                    locations: .init(progression: Double(page) / 5))
        }

        func go(to locator: Locator) -> Bool {
            chapter = Int(locator.href.string.dropFirst(2).prefix(while: \.isNumber))! - 4
            page = Int(((locator.locations.progression ?? 0) * 5).rounded())
            return true
        }

        func step(forward: Bool) -> Bool {
            if forward {
                if page < 4 { page += 1 } else if chapter < 1 { chapter += 1; page = 0 } else { return false }
            } else {
                if page > 0 { page -= 1 } else if chapter > 0 { chapter -= 1; page = 0 } else { return false }
            }
            return true
        }
    }

    private func turnAndSpringBack(_ book: Book, forward: Bool) async {
        let start = book.location
        _ = book.step(forward: forward)
        await CurlRelease.springBack(to: start, mirrored: !forward,
                                     go: { book.go(to: $0) }, step: { book.step(forward: $0) })
    }

    @Test func aTurnFromAChaptersLastPageSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 0; book.page = 4
        await turnAndSpringBack(book, forward: true)
        #expect(book.location == Book.locator(0, 4), "sprang back to \(book.location.href.string) @\(book.location.locations.progression ?? -1)")
    }

    @Test func aTurnInsideAChapterSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        await turnAndSpringBack(book, forward: true)
        #expect(book.location == Book.locator(1, 2))
        await turnAndSpringBack(book, forward: false)
        #expect(book.location == Book.locator(1, 2))
    }

    @Test func aTurnBackFromAChaptersFirstPageSpringsBackToThatPage() async {
        let book = Book()
        book.chapter = 1; book.page = 0
        await turnAndSpringBack(book, forward: false)
        #expect(book.location == Book.locator(1, 0))
    }

    /// A turn whose start wasn't read steps back a page, as before.
    @Test func anUnknownStartStepsBack() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        _ = book.step(forward: true)
        await CurlRelease.springBack(to: nil, mirrored: false, go: { book.go(to: $0) }, step: { book.step(forward: $0) })
        #expect(book.location == Book.locator(1, 2))
    }

    /// A jump back that fails falls back to the step.
    @Test func aFailedJumpStepsBack() async {
        let book = Book()
        book.chapter = 1; book.page = 2
        let start = book.location
        _ = book.step(forward: true)
        var tried = false
        await CurlRelease.springBack(to: start, mirrored: false, go: { _ in tried = true; return false }, step: { book.step(forward: $0) })
        #expect(tried)
        #expect(book.location == Book.locator(1, 2))
    }
}
