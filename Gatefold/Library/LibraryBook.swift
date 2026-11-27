import Foundation
import GatefoldCore

/// A book on this device's shelf: from the Cloud, imported from Files, or both.
struct LibraryBook: Identifiable, Codable, Equatable {
    enum Origin: String, Codable {
        case cloud
        case imported
    }

    /// Where a book that isn't from the Cloud came in, for the shelf's "From Files" and the counts-only telemetry.
    enum Source: String, Codable, CaseIterable {
        /// Chosen in Files from the shelf's Add menu.
        case files
        /// Handed over by another app: Open in, the share sheet, a tapped attachment.
        case shared
        /// Dropped on the shelf (iPad, or a Mac).
        case dropped
        /// Got from an OPDS catalog (`CatalogsView`).
        case catalog
        /// Found in the folder the reader asked Gatefold to watch (`WatchedFolder`).
        case folder
        /// One of the classics that ship in the app, from the empty shelf's Try a Few Classics.
        case sample
    }

    var id: String
    var title: String
    var author: String
    var origin: Origin
    /// How an imported book came in. Nil for Cloud books and for books imported before Gatefold kept it.
    var source: Source?
    /// Hex SHA-256 of the file kept here, so the same book coming in again is spotted (`ShelfMatch`).
    var digest: String?
    /// The Cloud's record, for Cloud books.
    var cloud: CloudBook?
    /// File name under the app's Books folder, once the book is on this device.
    var fileName: String?
    /// The Readium locator JSON of the last place read here.
    var locatorJSON: String?
    var totalProgression: Double = 0
    var lastOpened: Date?
    /// The other device's place, as last seen.
    var remote: ReadingPosition?
    var added: Date
    var bookmarks = BookmarkList()
    /// When the reader turned past the last page of the story here.
    var finished: Date?
    /// The first time the book was opened here, and how many times since, for the end leaf.
    var started: Date?
    var sessions: Int?
    /// The earliest sign that another device (the InkPad) was reading this book, and which, for the
    /// end leaf's "Started on your e-reader, finished here…" line.
    var otherSince: Date?
    var otherDevice: String?
    /// Set when the reader landed on a Cloud place the Cloud counts further on than Readium does.
    var cloudScale: CloudScale?

    var isOnDevice: Bool { fileName != nil }

    /// The shelf's word for a book not yet opened: where it came from.
    var arrivalLabel: String {
        guard origin == .imported else { return "New" }
        switch source {
        case .files: return "From Files"
        case .catalog: return "From a catalog"
        case .folder: return "From your folder"
        case .shared, .dropped, .sample, nil: return "Added"
        }
    }
    /// A book from the fake Cloud's bundled demo shelf.
    var isDemo: Bool { id.hasPrefix("gutenberg-") }
    var isFinished: Bool { finished != nil || cloud?.readStatus == "read" }

    /// On the Cloud's scale once he has landed on a Cloud place (`cloudScale`), so the shelf agrees with the InkPad.
    var displayProgression: Double {
        max(cloudScale?.onCloudScale(totalProgression) ?? totalProgression, lastOpened == nil ? (remote?.totalProgression ?? 0) : 0)
    }

    /// The shelf's "percent read": the same whole percent PocketBook's readers show for this place.
    var displayPercent: Int { ReadingPercent.whole(displayProgression) }

    var shelfItem: ShelfItem {
        ShelfItem(id: id, progression: displayProgression, lastOpened: lastOpened, remoteUpdated: remote?.updated)
    }

    /// Remembers the earliest place another device left, so the end leaf can tell where the read began.
    mutating func noteOtherDevice(_ position: ReadingPosition?) {
        guard let position, position.source != .gatefold, position.totalProgression > 0.005 else { return }
        if otherSince.map({ position.updated < $0 }) ?? true {
            otherSince = position.updated
            otherDevice = position.source == .pocketBookWeb ? "web reader" : "e-reader"
        }
    }

    var localSnapshot: ProgressSnapshot? {
        guard let lastOpened else { return nil }
        return ProgressSnapshot(totalProgression: totalProgression, updated: lastOpened, device: "iPhone")
    }
}

enum DownloadState: Equatable {
    case cloudOnly
    case downloading
    case onDevice
    case failed(String)
}
