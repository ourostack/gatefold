import Foundation
import GatefoldCore

/// A book on this device's shelf: from the Cloud, imported from Files, or both.
struct LibraryBook: Identifiable, Codable, Equatable {
    enum Origin: String, Codable {
        case cloud
        case imported
    }

    var id: String
    var title: String
    var author: String
    var origin: Origin
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
