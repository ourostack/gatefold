import Testing
@testable import GatefoldCore

/// One shelf: a book that comes in a second time, from anywhere, is the book already there.
@Suite struct ShelfMatchTests {
    let incoming = ShelfMatch.Fingerprint(sha256: "aaa", md5Base64: "bW Q1", bytes: 1200)

    @Test func newBytesAreANewBook() {
        let shelf = [ShelfMatch.Candidate(id: "local-1", sha256: "zzz", isOnDevice: true)]
        #expect(ShelfMatch.match(incoming, on: shelf) == .new)
        #expect(ShelfMatch.match(incoming, on: []) == .new)
    }

    @Test func theSameBytesOnTheShelfAreTheSameBook() {
        let shelf = [
            ShelfMatch.Candidate(id: "local-1", sha256: "zzz", isOnDevice: true),
            ShelfMatch.Candidate(id: "local-2", sha256: "aaa", isOnDevice: true),
        ]
        #expect(ShelfMatch.match(incoming, on: shelf) == .alreadyHere("local-2"))
    }

    @Test func aDownloadedPocketBookBookWithTheSameBytesIsTheSameBook() {
        let shelf = [ShelfMatch.Candidate(id: "fast-hash-1", sha256: "aaa", cloudMD5: "bW Q1", cloudBytes: 1200, isOnDevice: true)]
        #expect(ShelfMatch.match(incoming, on: shelf) == .alreadyHere("fast-hash-1"))
    }

    @Test func aPocketBookBookStillInTheCloudTakesTheFile() {
        // Its place keeps syncing with the e-reader, and the file need not be downloaded again.
        let shelf = [ShelfMatch.Candidate(id: "fast-hash-1", cloudMD5: "bW Q1", cloudBytes: 1200, isOnDevice: false)]
        #expect(ShelfMatch.match(incoming, on: shelf) == .takeCloudBook("fast-hash-1"))
    }

    @Test func aCloudChecksumWithADifferentSizeIsNotTrusted() {
        let shelf = [ShelfMatch.Candidate(id: "fast-hash-1", cloudMD5: "bW Q1", cloudBytes: 999, isOnDevice: false)]
        #expect(ShelfMatch.match(incoming, on: shelf) == .new)
    }

    @Test func aCloudBookAlreadyOnDeviceWithMatchingChecksumIsAlreadyHere() {
        // Downloaded before Gatefold kept digests: its checksum still says it is this file.
        let shelf = [ShelfMatch.Candidate(id: "fast-hash-1", cloudMD5: "bW Q1", cloudBytes: 1200, isOnDevice: true)]
        #expect(ShelfMatch.match(incoming, on: shelf) == .alreadyHere("fast-hash-1"))
    }

    @Test func noChecksumMatchesNothing() {
        let bare = ShelfMatch.Fingerprint(sha256: nil, md5Base64: nil, bytes: 1200)
        let shelf = [ShelfMatch.Candidate(id: "a", sha256: nil, cloudMD5: nil, cloudBytes: 1200, isOnDevice: false)]
        #expect(ShelfMatch.match(bare, on: shelf) == .new)
    }
}
