import Foundation
import Testing
@testable import GatefoldCore

/// Books arrive as zipped EPUBs, as EPUB folders (the way Apple Books keeps them on a Mac), or as
/// folders full of either. Everything Gatefold keeps is a zipped EPUB.
@Suite struct BookFileTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An exploded EPUB: what a Mac's Books library holds for a book its owner added.
    private func makeFolderBook(in dir: URL, name: String = "Persuasion.epub", mimetype: Bool = true) throws -> URL {
        let book = dir.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: book.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: book.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        if mimetype { try Data("application/epub+zip".utf8).write(to: book.appendingPathComponent("mimetype")) }
        try Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)
            .write(to: book.appendingPathComponent("META-INF/container.xml"))
        try Data("<package/>".utf8).write(to: book.appendingPathComponent("OEBPS/content.opf"))
        try Data("<html><body><p>It is a truth…</p></body></html>".utf8).write(to: book.appendingPathComponent("OEBPS/chapter 1.xhtml"))
        try Data("junk".utf8).write(to: book.appendingPathComponent(".DS_Store"))
        return book
    }

    @Test func crcMatchesTheStandardCheckValue() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func tellsBookFilesApart() throws {
        let dir = try scratch()
        let folderBook = try makeFolderBook(in: dir)
        let packed = try scratch().appendingPathComponent("packed.epub")
        try BookFile.pack(folder: folderBook, to: packed)
        let pdf = dir.appendingPathComponent("a.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: pdf)
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let plain = dir.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        #expect(BookFile.kind(at: folderBook) == .epubFolder)
        #expect(BookFile.kind(at: packed) == .epub)
        #expect(BookFile.kind(at: pdf) == .pdf)
        #expect(BookFile.kind(at: text) == .other)
        #expect(BookFile.kind(at: plain) == .folder)
        #expect(BookFile.kind(at: dir.appendingPathComponent("missing.epub")) == .other)
    }

    @Test func packsAFolderBookAsAnEPUBWithItsMimetypeFirstAndStored() throws {
        let dir = try scratch()
        let book = try makeFolderBook(in: dir)
        let out = dir.appendingPathComponent("out.epub")
        try BookFile.pack(folder: book, to: out)
        let entries = try ZipEntries.read(Data(contentsOf: out))
        // OCF: "mimetype" first, stored, with no extra field, so readers can sniff it at byte 30.
        #expect(entries.first?.name == "mimetype")
        #expect(entries.first?.method == 0)
        #expect(entries.first?.data == Data("application/epub+zip".utf8))
        let raw = try Data(contentsOf: out)
        #expect(String(decoding: raw[30 ..< 38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: raw[38 ..< 58], as: UTF8.self) == "application/epub+zip")
        let names = entries.map(\.name)
        #expect(names.contains("META-INF/container.xml"))
        #expect(names.contains("OEBPS/chapter 1.xhtml"))
        #expect(!names.contains(".DS_Store"))
        // Every entry's checksum is right, and the central directory agrees with the local headers.
        for entry in entries { #expect(entry.crc == ZipWriter.crc32(entry.data)) }
        #expect(entries.allSatisfy { $0.centralMatchesLocal })
    }

    @Test func packingAddsAMissingMimetype() throws {
        let dir = try scratch()
        let book = try makeFolderBook(in: dir, mimetype: false)
        let out = dir.appendingPathComponent("out.epub")
        try BookFile.pack(folder: book, to: out)
        let entries = try ZipEntries.read(Data(contentsOf: out))
        #expect(entries.first?.name == "mimetype")
        #expect(entries.first?.data == Data("application/epub+zip".utf8))
    }

    @Test func packingTheSameFolderTwiceGivesTheSameBytes() throws {
        // Same bytes, same digest: a book dropped in twice is spotted as the one already on the shelf.
        let dir = try scratch()
        let book = try makeFolderBook(in: dir)
        let a = dir.appendingPathComponent("a.epub"), b = dir.appendingPathComponent("b.epub")
        try BookFile.pack(folder: book, to: a)
        try BookFile.pack(folder: book, to: b)
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
    }

    @Test func findsTheBooksInAFolderWithoutGoingInsideFolderBooks() throws {
        let dir = try scratch()
        _ = try makeFolderBook(in: dir, name: "Emma.epub")
        let sub = dir.appendingPathComponent("Austen/More", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makeFolderBook(in: sub, name: "Persuasion.epub")
        let zipped = dir.appendingPathComponent("Austen/Sense.epub")
        try BookFile.pack(folder: dir.appendingPathComponent("Emma.epub"), to: zipped)
        try Data("%PDF".utf8).write(to: dir.appendingPathComponent("scan.pdf"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.epub"))
        let found = BookFile.books(in: dir).map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") }.sorted()
        #expect(found == ["Austen/More/Persuasion.epub", "Austen/Sense.epub", "Emma.epub"])
    }

    /// A folder in iCloud Drive is listed without reading its books, so one not downloaded yet isn't
    /// pulled down at the listing, and iCloud's stand-in for it still counts.
    @Test func listsBooksByNameWithoutReadingThem() throws {
        let dir = try scratch()
        let later = dir.appendingPathComponent("Later", isDirectory: true)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        try Data().write(to: later.appendingPathComponent("Dracula.EPUB")) // a name with no bytes behind it yet
        try Data("x".utf8).write(to: dir.appendingPathComponent(".Persuasion.epub.icloud"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".notes.txt.icloud"))
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let found = BookFile.books(in: dir).map { $0.path.replacingOccurrences(of: dir.path + "/", with: "") }.sorted()
        #expect(found == ["Later/Dracula.EPUB", "Persuasion.epub"])
    }

    /// A link from inside a folder back up to it is passed over, instead of being followed for ever.
    @Test func linksBackUpTheFolderAreNotFollowed() throws {
        let dir = try scratch()
        let book = try makeFolderBook(in: dir, name: "Emma.epub")
        try FileManager.default.createSymbolicLink(at: book.appendingPathComponent("OEBPS/loop"), withDestinationURL: book)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("again"), withDestinationURL: dir)
        let packed = try scratch().appendingPathComponent("packed.epub")
        try BookFile.pack(folder: book, to: packed)
        let names = try ZipEntries.read(Data(contentsOf: packed)).map(\.name)
        #expect(!names.contains { $0.contains("loop") })
        #expect(BookFile.books(in: dir).map(\.lastPathComponent) == ["Emma.epub"])
    }
}

/// A minimal ZIP reader for the tests: local headers checked against the central directory.
private struct ZipEntries {
    struct Entry {
        var name: String
        var method: UInt16
        var crc: UInt32
        var data: Data
        var centralMatchesLocal: Bool
    }

    static func read(_ zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
        // End of central directory: the last 22 bytes when there's no comment.
        let eocd = bytes.count - 22
        guard u32(eocd) == 0x0605_4B50 else { throw CocoaError(.fileReadCorruptFile) }
        let count = Int(u16(eocd + 10))
        var cd = Int(u32(eocd + 16))
        var out: [Entry] = []
        for _ in 0 ..< count {
            guard u32(cd) == 0x0201_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            let crc = u32(cd + 16), size = Int(u32(cd + 20)), nameLength = Int(u16(cd + 28))
            let extra = Int(u16(cd + 30)), comment = Int(u16(cd + 32)), local = Int(u32(cd + 42))
            let name = String(decoding: bytes[(cd + 46) ..< (cd + 46 + nameLength)], as: UTF8.self)
            guard u32(local) == 0x0403_4B50 else { throw CocoaError(.fileReadCorruptFile) }
            let localName = Int(u16(local + 26)), localExtra = Int(u16(local + 28))
            let start = local + 30 + localName + localExtra
            let matches = u32(local + 14) == crc && Int(u32(local + 18)) == size && localName == nameLength
            out.append(Entry(name: name, method: u16(local + 8), crc: crc, data: Data(bytes[start ..< (start + size)]), centralMatchesLocal: matches))
            cd += 46 + nameLength + extra + comment
        }
        return out
    }
}
