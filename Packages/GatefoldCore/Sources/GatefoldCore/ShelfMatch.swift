/// Whether a book coming in (from Files, the share sheet, a folder or a catalog) is one already on the
/// shelf. One shelf, no duplicates: the same bytes are the same book, and a PocketBook Cloud book whose
/// checksum is this file's takes the file instead of a second copy going on the shelf.
public enum ShelfMatch: Equatable, Sendable {
    /// These bytes are already this book's file.
    case alreadyHere(String)
    /// This Cloud book, not yet on this device, is this file: it takes the file and keeps its Cloud link.
    case takeCloudBook(String)
    case new

    public struct Fingerprint: Equatable, Sendable {
        /// Hex SHA-256 of the file Gatefold keeps.
        public var sha256: String?
        /// Base64 MD5 of the same file, the checksum PocketBook Cloud lists.
        public var md5Base64: String?
        public var bytes: Int64?

        public init(sha256: String?, md5Base64: String?, bytes: Int64?) {
            self.sha256 = sha256
            self.md5Base64 = md5Base64
            self.bytes = bytes
        }
    }

    public struct Candidate: Equatable, Sendable {
        public var id: String
        /// The digest of the file this book has here, when Gatefold has taken it.
        public var sha256: String?
        /// The Cloud's checksum and size, only when the checksum really is an MD5 (`CloudBook.verifiableMD5`).
        public var cloudMD5: String?
        public var cloudBytes: Int64?
        public var isOnDevice: Bool

        public init(id: String, sha256: String? = nil, cloudMD5: String? = nil, cloudBytes: Int64? = nil, isOnDevice: Bool) {
            self.id = id
            self.sha256 = sha256
            self.cloudMD5 = cloudMD5
            self.cloudBytes = cloudBytes
            self.isOnDevice = isOnDevice
        }
    }

    public static func match(_ incoming: Fingerprint, on shelf: [Candidate]) -> ShelfMatch {
        if let sha = incoming.sha256, let same = shelf.first(where: { $0.sha256 == sha }) {
            return .alreadyHere(same.id)
        }
        // The Cloud's checksum counts only with its size agreeing: a stray checksum alone is too thin.
        if let md5 = incoming.md5Base64, let bytes = incoming.bytes,
           let cloud = shelf.first(where: { $0.cloudMD5 == md5 && $0.cloudBytes == bytes }) {
            return cloud.isOnDevice ? .alreadyHere(cloud.id) : .takeCloudBook(cloud.id)
        }
        return .new
    }
}
