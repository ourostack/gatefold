import Foundation

/// What a file handed to Gatefold is, and how it becomes a book on the shelf. Gatefold keeps every book
/// as a zipped EPUB. An EPUB folder (how Apple Books keeps the books its owner added, on a Mac: the
/// `org.idpf.epub-folder` package) is zipped on the way in, so the reader never sees the difference.
public enum BookFile {
    public enum Kind: Equatable, Sendable {
        /// A zipped EPUB (`.epub`, `.kepub.epub`).
        case epub
        /// An unzipped EPUB: a folder with `META-INF/container.xml`.
        case epubFolder
        case pdf
        /// A plain folder, which may hold books.
        case folder
        case other
    }

    public static func kind(at url: URL) -> Kind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .other }
        if isDirectory.boolValue {
            let container = url.appendingPathComponent("META-INF/container.xml")
            return FileManager.default.fileExists(atPath: container.path) ? .epubFolder : .folder
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)) ?? Data()
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf } // %PDF
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // PK: a zip
            // An EPUB says so at byte 30; a zip that doesn't still counts when it's called .epub (Readium decides).
            let sniffed = head.count >= 58 && String(decoding: head[38 ..< 58], as: UTF8.self) == "application/epub+zip"
            return sniffed || url.pathExtension.lowercased() == "epub" ? .epub : .other
        }
        return .other
    }

    /// Zips an EPUB folder into `destination`: `mimetype` first and stored, as the EPUB container
    /// format asks, then every other file, stored, in a fixed order so the same folder always gives
    /// the same bytes. Hidden files (`.DS_Store`) stay out.
    public static func pack(folder: URL, to destination: URL) throws {
        let files = try contents(of: folder)
        var writer = try ZipWriter(to: destination)
        let mimetype = folder.appendingPathComponent("mimetype")
        let ownMimetype = (try? Data(contentsOf: mimetype)).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        try writer.add(name: "mimetype", data: Data((ownMimetype?.isEmpty == false ? ownMimetype! : "application/epub+zip").utf8))
        for path in files where path != "mimetype" {
            try writer.add(name: path, data: Data(contentsOf: folder.appendingPathComponent(path)))
        }
        try writer.finish()
    }

    /// The books in `folder`, by name alone, without reading any file: a `.epub` file, or a folder that
    /// holds `META-INF/container.xml`; folders inside are searched too, a few levels down, and never a folder
    /// that is itself a book. Nothing is read, so listing a folder in iCloud Drive doesn't download every
    /// book in it; each is read (and so downloaded) only as it comes aboard. Hidden files and links to
    /// folders are passed over, except iCloud's stand-in for a book not downloaded yet
    /// (`.Emma.epub.icloud`), which stands for `Emma.epub`.
    public static func books(in folder: URL, depth: Int = 4) -> [URL] {
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [URL] = []
        for name in names.sorted() {
            if name.hasPrefix(".") {
                let real = String(name.dropFirst())
                if real.hasSuffix(".icloud"), real.dropLast(".icloud".count).lowercased().hasSuffix(".epub") {
                    found.append(folder.appendingPathComponent(String(real.dropLast(".icloud".count))))
                }
                continue
            }
            let url = folder.appendingPathComponent(name)
            guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { continue }
            if type == .typeDirectory {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("META-INF/container.xml").path) {
                    found.append(url)
                } else {
                    found += books(in: url, depth: depth - 1)
                }
            } else if type == .typeRegular, url.pathExtension.lowercased() == "epub" {
                found.append(url)
            }
        }
        return found
    }

    /// Every file under `folder`, as paths relative to it, sorted, hidden ones left out.
    private static func contents(of folder: URL) throws -> [String] {
        var out: [String] = []
        func walk(_ dir: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                // A link is passed over: one pointing back up the folder would never end.
                switch try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
                case .typeDirectory?: try walk(url, prefix + name + "/")
                case .typeRegular?: out.append(prefix + name)
                default: break
                }
            }
        }
        try walk(folder, "")
        return out
    }
}

/// Writes a ZIP of stored (uncompressed) entries, which is all an EPUB needs: its text is small, and
/// its pictures are compressed already.
public struct ZipWriter {
    private let handle: FileHandle
    private var offset: UInt32 = 0
    private var central = Data()
    private var count: UInt16 = 0

    public enum ZipError: Error { case tooLarge }

    public init(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    public mutating func add(name: String, data: Data) throws {
        let nameBytes = Data(name.utf8)
        guard data.count < Int(UInt32.max) - 1024, UInt64(offset) + UInt64(data.count) < UInt64(UInt32.max) - 65536 else {
            throw ZipError.tooLarge
        }
        let crc = Self.crc32(data)
        let size = UInt32(data.count)
        // Bit 11: the name is UTF-8. A fixed date (1980-01-01), so the same files give the same bytes.
        let flags: UInt16 = 0x0800, time: UInt16 = 0, date: UInt16 = 0x21
        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(flags); local.le16(0); local.le16(time); local.le16(date)
        local.le32(crc); local.le32(size); local.le32(size); local.le16(UInt16(nameBytes.count)); local.le16(0)
        local.append(nameBytes)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)

        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(flags); central.le16(0)
        central.le16(time); central.le16(date); central.le32(crc); central.le32(size); central.le32(size)
        central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(0); central.le32(offset)
        central.append(nameBytes)

        offset += UInt32(local.count) + size
        guard count < UInt16.max else { throw ZipError.tooLarge }
        count += 1
    }

    public mutating func finish() throws {
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(central.count)); end.le32(offset); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}
