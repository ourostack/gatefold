import Foundation
import Testing
@testable import GatefoldCore

/// Fixtures are shaped like each server's output today: trimmed public captures for Project Gutenberg and
/// Standard Ebooks, and small hand-written feeds built from calibre, Calibre-Web, Kavita and Komga's source.
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/OPDS"))
    return try Data(contentsOf: url)
}

private func url(_ string: String) -> URL { URL(string: string)! }

private func parse(_ name: String, from feed: String) throws -> CatalogFeed {
    try CatalogParser.parse(data: fixture(name), from: #require(URL(string: feed)))
}

@Suite("Project Gutenberg's catalog opens, pages back and finds the EPUB with images")
struct CatalogGutenbergTests {
    @Test func rootListsItsShelvesAndSearchesThroughOpenSearch() throws {
        let feed = try parse("gutenberg-root.xml", from: "https://www.gutenberg.org/ebooks.opds/")
        #expect(feed.title == "Project Gutenberg")
        #expect(feed.entries.map(\.title) == ["Popular", "Latest"])
        #expect(feed.entries[0].navigation?.absoluteString == "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads")
        #expect(feed.entries[0].summary == "Our most popular books.")
        // Gutenberg inlines its shelf icons as data: URLs; they are not worth a cover slot.
        #expect(feed.entries[0].thumbnail == nil)
        #expect(feed.entries[0].epub == nil)
        #expect(feed.next == nil)
        #expect(feed.search == .description(url("https://www.gutenberg.org/catalog/osd-books.xml")))
    }

    @Test func openSearchTemplateMovesToHTTPSOnWww() throws {
        let search = try #require(OpenSearchDescription.parse(fixture("gutenberg-osd.xml"), from: url("https://www.gutenberg.org/catalog/osd-books.xml")))
        #expect(search == .template("https://www.gutenberg.org/ebooks/search.opds/?query={searchTerms}"))
        #expect(search.url(for: "moby dick")?.absoluteString == "https://www.gutenberg.org/ebooks/search.opds/?query=moby%20dick")
    }

    @Test func searchResultsOpenEachBookAndPageBack() throws {
        let feed = try parse("gutenberg-search.xml", from: "https://www.gutenberg.org/ebooks/search.opds/?query=%22city+hall%22&start_index=26")
        #expect(feed.title == "Books: city hall")
        #expect(feed.entries.count == 3)
        let first = feed.entries[0]
        #expect(first.id == "https://www.gutenberg.org/ebooks/39434.opds")
        #expect(first.title == "Vistas of New York")
        #expect(first.summary == "Brander Matthews")
        #expect(first.navigation?.absoluteString == "https://www.gutenberg.org/ebooks/39434.opds")
        #expect(first.epub == nil)
        #expect(feed.previous?.absoluteString == "https://www.gutenberg.org/ebooks/search.opds/?query=%22city+hall%22")
        #expect(feed.next == nil)
    }

    @Test func bookFeedOffersEachEditionAndPrefersEPUB3WithImages() throws {
        let feed = try parse("gutenberg-book.xml", from: "https://www.gutenberg.org/ebooks/84.opds")
        #expect(feed.entries.count == 2)
        let plain = feed.entries[0], illustrated = feed.entries[1]
        #expect(plain.id == "urn:gutenberg:84:2")
        #expect(plain.author == "Shelley, Mary Wollstonecraft")
        // "related" links point at the author's other books, not into this one.
        #expect(plain.navigation == nil)
        #expect(plain.epub?.url.absoluteString == "https://www.gutenberg.org/ebooks/84.epub.noimages")
        #expect(illustrated.acquisitions.count == 4)
        #expect(illustrated.epub?.url.absoluteString == "https://www.gutenberg.org/ebooks/84.epub3.images")
        #expect(illustrated.epub?.length == 440131)
        #expect(illustrated.epub?.mediaType == "application/epub+zip")
        #expect(illustrated.cover?.absoluteString == "https://www.gutenberg.org/cache/epub/84/pg84.cover.medium.jpg")
        #expect(illustrated.thumbnail?.absoluteString == "https://www.gutenberg.org/cache/epub/84/pg84.cover.small.jpg")
    }

    @Test func oldMobileHostResolvesToHTTPSWww() throws {
        // App Transport Security refuses plain http, and m.gutenberg.org now only redirects.
        let feed = try parse("gutenberg-search.xml", from: "http://m.gutenberg.org/ebooks/search.opds/?query=city")
        #expect(feed.entries[0].navigation?.absoluteString == "https://www.gutenberg.org/ebooks/39434.opds")
    }
}

@Suite("Standard Ebooks' plain Atom feed is read as a catalog of enclosures")
struct CatalogStandardEbooksTests {
    @Test func enclosuresAreAcquisitionsAndTheCompatibleEPUBWins() throws {
        let feed = try parse("standard-ebooks-new-releases.xml", from: "https://standardebooks.org/feeds/atom/new-releases")
        #expect(feed.title == "Standard Ebooks - Newest Ebooks")
        #expect(feed.entries.count == 2)
        let zeno = feed.entries[0]
        #expect(zeno.title == "Confessions of Zeno")
        #expect(zeno.author == "Italo Svevo")
        #expect(zeno.summary == "To quit smoking, a man writes his memoirs.")
        #expect(zeno.acquisitions.count == 5)
        #expect(zeno.epub?.url.absoluteString == "https://standardebooks.org/ebooks/italo-svevo/confessions-of-zeno/beryl-de-zoete/downloads/italo-svevo_confessions-of-zeno_beryl-de-zoete.epub?source=feed")
        #expect(zeno.thumbnail?.absoluteString == "https://standardebooks.org/ebooks/italo-svevo/confessions-of-zeno/beryl-de-zoete/downloads/cover-thumbnail.jpg")
        // The alternate link is the book's web page, not a feed.
        #expect(zeno.navigation == nil)
        #expect(feed.search == .description(url("https://standardebooks.org/opensearch")))
    }
}

@Suite("calibre's content server: rel-less navigation, direct search, offset paging")
struct CatalogCalibreTests {
    @Test func rootNavigatesByLinkTypeAndSearchesDirectly() throws {
        let feed = try parse("calibre-root.xml", from: "http://calibre.local:8080/opds")
        #expect(feed.title == "calibre Library")
        #expect(feed.entries.map(\.title) == ["By Newest", "By Authors"])
        #expect(feed.entries[0].navigation?.absoluteString == "http://calibre.local:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library")
        #expect(feed.search == .template("http://calibre.local:8080/opds/search/{searchTerms}?library_id=Calibre_Library"))
        #expect(feed.search?.url(for: "austen & co")?.absoluteString == "http://calibre.local:8080/opds/search/austen%20%26%20co?library_id=Calibre_Library")
    }

    @Test func booksPageResolvesDownloadsAndCoversAndPagesOn() throws {
        let feed = try parse("calibre-books.xml", from: "http://calibre.local:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library")
        #expect(feed.next?.absoluteString == "http://calibre.local:8080/opds/navcatalog/4f6e6577657374?library_id=Calibre_Library&offset=25")
        let pride = feed.entries[0]
        #expect(pride.id == "urn:uuid:3c4b6f0e-6c1d-4b8e-9b0a-2f3e4d5c6b7a")
        #expect(pride.author == "Jane Austen")
        #expect(pride.epub?.url.absoluteString == "http://calibre.local:8080/get/epub/3/Calibre_Library")
        #expect(pride.epub?.length == 512000)
        #expect(pride.cover?.absoluteString == "http://calibre.local:8080/get/cover/3/Calibre_Library")
        #expect(pride.thumbnail?.absoluteString == "http://calibre.local:8080/get/thumb/3/Calibre_Library")
        #expect(pride.summary?.contains("A novel of manners.") == true)
        // A PDF-only book still lists, so the shelf can show it as unavailable.
        let pickwick = feed.entries[1]
        #expect(pickwick.acquisitions.map(\.mediaType) == ["application/pdf"])
        #expect(pickwick.epub == nil)
        #expect(pickwick.navigation == nil)
    }
}

@Suite("Calibre-Web: entries with no rel, and its OpenSearch description")
struct CatalogCalibreWebTests {
    @Test func relLessLinksNavigateAndTheDirectTemplateBeatsTheDescription() throws {
        let feed = try parse("calibre-web-root.xml", from: "http://books.local:8083/opds")
        #expect(feed.entries.map(\.title) == ["Alphabetical Books", "Recently added Books", "Shelves"])
        #expect(feed.entries.map { $0.navigation?.absoluteString } == [
            "http://books.local:8083/opds/books", "http://books.local:8083/opds/new", "http://books.local:8083/opds/shelfindex",
        ])
        #expect(feed.search == .template("http://books.local:8083/opds/search/{searchTerms}"))
    }

    @Test func openSearchPicksTheAtomTemplateAndResolvesIt() throws {
        let search = try #require(OpenSearchDescription.parse(fixture("calibre-web-osd.xml"), from: url("http://books.local:8083/opds/osd")))
        #expect(search == .template("http://books.local:8083/opds/search?query={searchTerms}"))
        #expect(search.url(for: "Les Misérables")?.absoluteString == "http://books.local:8083/opds/search?query=Les%20Mis%C3%A9rables")
    }
}

@Suite("Kavita: open-access acquisitions, prev paging, mostly comics")
struct CatalogKavitaTests {
    @Test func onlyTheEPUBChapterIsReadable() throws {
        let feed = try parse("kavita-series.xml", from: "http://kavita.local:5000/api/opds/2f7c3a9e-key/series/12?pageNumber=2")
        #expect(feed.title == "Little Nemo in Slumberland - Storyline")
        #expect(feed.entries.count == 3)
        #expect(feed.entries[0].acquisitions.map(\.rel) == ["http://opds-spec.org/acquisition/open-access"])
        #expect(feed.entries[0].acquisitions.map(\.mediaType) == ["application/x-cbz"])
        #expect(feed.entries[0].epub == nil)
        #expect(feed.entries[0].author == "Winsor McCay")
        #expect(feed.entries[2].epub?.url.absoluteString == "http://kavita.local:5000/api/opds/2f7c3a9e-key/series/12/volume/40/chapter/140/download/Dreams%20of%20the%20Rarebit%20Fiend.epub")
        #expect(feed.entries[2].cover?.absoluteString == "http://kavita.local:5000/api/image/chapter-cover?chapterId=140&apiKey=2f7c3a9e-key")
        #expect(feed.previous?.absoluteString == "http://kavita.local:5000/api/opds/2f7c3a9e-key/series/12?pageNumber=1")
        #expect(feed.next?.absoluteString == "http://kavita.local:5000/api/opds/2f7c3a9e-key/series/12?pageNumber=3")
        #expect(feed.search == .description(url("http://kavita.local:5000/api/opds/2f7c3a9e-key/search")))
    }

    @Test func openSearchMatchesTheAtomTypeWithItsParameters() throws {
        let osd = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <ShortName>Search</ShortName>
              <Description>Search for Series, Collections, or Reading Lists</Description>
              <Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/api/opds/2f7c3a9e-key/series?query={searchTerms}" />
            </OpenSearchDescription>
            """.utf8)
        let search = OpenSearchDescription.parse(osd, from: url("http://kavita.local:5000/api/opds/2f7c3a9e-key/search"))
        #expect(search == .template("http://kavita.local:5000/api/opds/2f7c3a9e-key/series?query={searchTerms}"))
    }
}

@Suite("Komga's OPDS 1.2 feed: absolute links, previous and next")
struct CatalogKomgaTests {
    @Test func epubBookIsReadableAndTheComicIsNot() throws {
        let feed = try parse("komga-latest-books.xml", from: "https://komga.example/opds/v1.2/books/latest?page=1")
        #expect(feed.title == "Latest books")
        #expect(feed.entries.map(\.author) == ["Herman Melville", "George Herriman"])
        #expect(feed.entries[0].epub?.url.absoluteString == "https://komga.example/opds/v1.2/books/0A1B2C3D4E5F6/file/Moby-Dick.epub")
        #expect(feed.entries[0].cover?.absoluteString == "https://komga.example/opds/v1.2/books/0A1B2C3D4E5F6/thumbnail")
        #expect(feed.entries[0].thumbnail?.absoluteString == "https://komga.example/opds/v1.2/books/0A1B2C3D4E5F6/thumbnail/small")
        #expect(feed.entries[1].epub == nil)
        #expect(feed.previous?.absoluteString == "https://komga.example/opds/v1.2/books/latest?page=0")
        #expect(feed.next?.absoluteString == "https://komga.example/opds/v1.2/books/latest?page=2")
        #expect(feed.search == .description(url("https://komga.example/opds/v1.2/search")))
    }
}

@Suite("OPDS 2.0 JSON: navigation, publications, groups and a templated search")
struct CatalogOPDS2Tests {
    @Test func navigationAndPublicationsBecomeEntries() throws {
        let feed = try parse("opds2-root.json", from: "https://shelf.example/opds/v2/catalog")
        #expect(feed.title == "Public Domain Shelf")
        #expect(feed.entries.map(\.title) == ["Fiction", "Poetry", "Moby-Dick; or, The Whale", "Leaves of Grass", "Walden"])
        #expect(feed.entries[0].navigation?.absoluteString == "https://shelf.example/opds/v2/fiction")
        #expect(feed.entries[1].navigation?.absoluteString == "https://shelf.example/opds/v2/poetry")
        let moby = feed.entries[2]
        #expect(moby.id == "urn:uuid:6f1b2a3c-0d4e-4f5a-8b6c-7d8e9f0a1b2c")
        #expect(moby.author == "Herman Melville")
        #expect(moby.summary == "The voyage of the Pequod.")
        #expect(moby.epub?.url.absoluteString == "https://shelf.example/books/moby-dick/file.epub")
        #expect(moby.cover?.absoluteString == "https://shelf.example/books/moby-dick/cover.jpg")
        #expect(moby.thumbnail?.absoluteString == "https://shelf.example/books/moby-dick/thumb.jpg")
        #expect(feed.entries[3].author == "Walt Whitman")
        #expect(feed.entries[3].epub == nil)
        #expect(feed.entries[4].author == "Henry David Thoreau")
        #expect(feed.entries[4].epub?.url.absoluteString == "https://shelf.example/books/walden/file.epub")
        #expect(feed.next?.absoluteString == "https://shelf.example/opds/v2/catalog?page=2")
    }

    @Test func templatedSearchExpandsTheQuery() throws {
        let feed = try parse("opds2-root.json", from: "https://shelf.example/opds/v2/catalog")
        #expect(feed.search == .template("https://shelf.example/opds/v2/search{?query}"))
        #expect(feed.search?.url(for: "white whale")?.absoluteString == "https://shelf.example/opds/v2/search?query=white%20whale")
    }
}

@Suite("Catalog search templates expand the way each spec says")
struct CatalogSearchTests {
    @Test(arguments: [
        ("https://x.example/s{?query,page}", "https://x.example/s?query=red%20fox"),
        ("https://x.example/s?lang=en{&query}", "https://x.example/s?lang=en&query=red%20fox"),
        ("https://x.example/s/{query}", "https://x.example/s/red%20fox"),
        ("https://x.example/s?q={searchTerms}&p={startPage?}", "https://x.example/s?q=red%20fox&p="),
        ("http://www.gutenberg.org/ebooks/search.opds/?query={searchTerms}", "https://www.gutenberg.org/ebooks/search.opds/?query=red%20fox"),
    ])
    func expands(_ template: String, _ expected: String) {
        #expect(CatalogSearch.template(template).url(for: "red fox")?.absoluteString == expected)
    }

    @Test func blankQueryAndUnfetchedDescriptionGiveNoURL() throws {
        #expect(CatalogSearch.template("https://x.example/s?q={searchTerms}").url(for: "  ") == nil)
        #expect(CatalogSearch.description(url("https://x.example/osd.xml")).url(for: "fox") == nil)
    }

    @Test func reservedCharactersAreEncoded() {
        #expect(CatalogSearch.template("https://x.example/s?q={searchTerms}").url(for: "a/b?c=d&e#f+g")?.absoluteString == "https://x.example/s?q=a%2Fb%3Fc%3Dd%26e%23f%2Bg")
    }
}

@Suite("A catalog entry picks the EPUB it can read")
struct CatalogEntryEPUBTests {
    private func acquisition(_ href: String, _ type: String = "application/epub+zip", rel: String = "http://opds-spec.org/acquisition", title: String? = nil) -> CatalogAcquisition {
        CatalogAcquisition(url: URL(string: href)!, mediaType: type, rel: rel, length: nil, title: title)
    }

    private func entry(_ acquisitions: [CatalogAcquisition]) -> CatalogEntry {
        CatalogEntry(id: "1", title: "Book", author: nil, summary: nil, navigation: nil, acquisitions: acquisitions, cover: nil, thumbnail: nil)
    }

    @Test func gutenbergEditionsRankByHref() {
        let book = entry([
            acquisition("https://www.gutenberg.org/ebooks/84.epub.noimages"),
            acquisition("https://www.gutenberg.org/ebooks/84.epub.images"),
            acquisition("https://www.gutenberg.org/ebooks/84.epub3.images"),
        ])
        #expect(book.epub?.url.absoluteString == "https://www.gutenberg.org/ebooks/84.epub3.images")
    }

    @Test func titlesTellWhenHrefsDoNot() {
        let book = entry([
            acquisition("https://x.example/get/1", title: "EPUB (no images)"),
            acquisition("https://x.example/get/2", title: "EPUB3"),
        ])
        #expect(book.epub?.url.absoluteString == "https://x.example/get/2")
    }

    @Test func paidOrPreviewLinksAreNotTheBook() {
        let book = entry([
            acquisition("https://x.example/buy", rel: "http://opds-spec.org/acquisition/buy"),
            acquisition("https://x.example/sample", rel: "http://opds-spec.org/acquisition/sample"),
            acquisition("https://x.example/book.mobi", "application/x-mobipocket-ebook"),
        ])
        #expect(book.epub == nil)
    }

    @Test func untypedDownloadEndingInEpubCounts() {
        #expect(entry([acquisition("https://x.example/files/walden.epub", "application/octet-stream")]).epub != nil)
    }
}

@Suite("Catalog parsing refuses what is not a catalog")
struct CatalogRefusalTests {
    @Test func htmlPageIsNotACatalog() throws {
        let page = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>OPDS</title></head><body/></html>".utf8)
        #expect(throws: CatalogError.self) {
            try CatalogParser.parse(data: page, from: URL(string: "https://standardebooks.org/feeds/opds")!)
        }
    }

    @Test func brokenBytesAreUnreadable() {
        #expect(throws: CatalogError.self) {
            try CatalogParser.parse(data: Data("{\"metadata\": ".utf8), from: URL(string: "https://x.example/opds")!)
        }
    }
}
