import Testing
@testable import GatefoldCore

@Suite struct BookStyleTests {
    @Test func goesAtTheEndOfTheHead() {
        let html = "<html><head><link rel=\"stylesheet\" href=\"0.css\"/></head><body><p>Hi</p></body></html>"
        let out = BookStyle.inject(into: html)
        let style = out.range(of: "gatefold-book-style")!
        #expect(out.range(of: "0.css")!.lowerBound < style.lowerBound)
        #expect(style.lowerBound < out.range(of: "</head>")!.lowerBound)
        #expect(out.hasSuffix("<body><p>Hi</p></body></html>"))
    }

    @Test func onlyOnce() {
        let once = BookStyle.inject(into: "<head></head>")
        #expect(BookStyle.inject(into: once) == once)
    }

    @Test func leavesAHeadlessDocumentAlone() {
        #expect(BookStyle.inject(into: "<p>no head</p>") == "<p>no head</p>")
    }

    @Test func hidesOnlyFiguresWithoutAPicture() {
        #expect(BookStyle.css.contains(":not(:has(img"))
    }

    @Test func chaptersOnly() {
        #expect(BookStyle.applies(toPath: "OEBPS/ch1.xhtml"))
        #expect(BookStyle.applies(toPath: "OEBPS/1342-h-13.htm.html"))
        #expect(!BookStyle.applies(toPath: "OEBPS/0.css"))
        #expect(!BookStyle.applies(toPath: "OEBPS/cover.jpg"))
    }
}
