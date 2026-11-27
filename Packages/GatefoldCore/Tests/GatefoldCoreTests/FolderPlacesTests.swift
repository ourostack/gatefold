import Foundation
import Testing
@testable import GatefoldCore

/// Places for books in a watched folder travel through the folder itself: each device writes only its
/// own file, so iCloud Drive never has two writers of one file to make conflict copies of.
@Suite struct FolderPlacesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func place(_ progression: Double, at seconds: TimeInterval, on device: String = "iPhone") -> FolderPlace {
        FolderPlace(locator: "{\"locations\":{\"totalProgression\":\(progression)}}", progression: progression,
                    updated: t0.addingTimeInterval(seconds), device: device)
    }

    @Test func eachDeviceHasItsOwnFile() {
        #expect(FolderPlaces.fileName(deviceID: "A1B2") == "places-A1B2.json")
        #expect(FolderPlaces.deviceID(fromFileName: "places-A1B2.json") == "A1B2")
        #expect(FolderPlaces.deviceID(fromFileName: "places-A1B2 2.json") == nil) // a conflict copy is never read
        #expect(FolderPlaces.deviceID(fromFileName: "notes.json") == nil)
    }

    @Test func aFileRoundTrips() throws {
        let file = FolderPlaceFile(device: "iPad", places: ["d1": place(0.4, at: 10, on: "iPad")])
        let data = try FolderPlaces.encode(file)
        #expect(try FolderPlaces.decode(data) == file)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func seen(_ progression: Double, at seconds: TimeInterval) -> FolderSyncMark.Seen {
        .init(updated: at(seconds), progression: progression)
    }

    @Test func withNothingSettledYetTheNewerPlaceIsTaken() {
        let pad = place(0.5, at: 20, on: "iPad")
        #expect(FolderPlaces.settle(["pad": pad], local: seen(0.2, at: 10), mark: nil) == .takeRemote(pad))
        #expect(FolderPlaces.settle(["pad": pad], local: nil, mark: nil) == .takeRemote(pad))
        #expect(FolderPlaces.settle(["pad": pad], local: seen(0.2, at: 30), mark: nil) == .keepLocal)
        #expect(FolderPlaces.settle([:], local: nil, mark: nil) == .keepLocal)
    }

    @Test func onlyAnotherDeviceMovedSoItsPlaceIsTakenEvenGoingBack() {
        let mark = FolderSyncMark(others: ["pad": seen(0.5, at: 10)], local: seen(0.5, at: 10))
        let back = place(0.1, at: 60, on: "iPad")
        #expect(FolderPlaces.settle(["pad": back], local: seen(0.5, at: 10), mark: mark) == .takeRemote(back))
    }

    @Test func onlyThisDeviceMovedSoItsPlaceStays() {
        let mark = FolderSyncMark(others: ["pad": seen(0.5, at: 10)], local: seen(0.5, at: 10))
        #expect(FolderPlaces.settle(["pad": place(0.5, at: 10, on: "iPad")], local: seen(0.2, at: 90), mark: mark) == .keepLocal)
    }

    @Test func whenBothMovedTheFurtherPlaceWins() {
        let mark = FolderSyncMark(others: ["phone": seen(0.1, at: 10)], local: seen(0.1, at: 10))
        // The iPhone read on to half way while the iPad had the book open at 10 %; the iPad then turned one
        // page. Newer, but further back: the iPhone's place wins on both.
        let phone = place(0.5, at: 60, on: "iPhone")
        #expect(FolderPlaces.settle(["phone": phone], local: seen(0.11, at: 120), mark: mark) == .takeRemote(phone))
        #expect(FolderPlaces.settle(["phone": place(0.05, at: 60)], local: seen(0.11, at: 120), mark: mark) == .keepLocal)
    }

    @Test func openingABookOnTheSamePageIsNotAMove() {
        let mark = FolderSyncMark(others: ["phone": seen(0.5, at: 10)], local: seen(0.5, at: 10))
        // The iPhone went back to reread; the iPad, opened on its old page, wrote that page again on landing.
        let reread = place(0.05, at: 60, on: "iPhone")
        #expect(FolderPlaces.settle(["phone": reread], local: seen(0.5, at: 70), mark: mark) == .takeRemote(reread))
        // And the other way round: a device that only opened the book hasn't moved.
        #expect(FolderPlaces.settle(["phone": place(0.5, at: 80)], local: seen(0.05, at: 60), mark: mark) == .keepLocal)
    }

    @Test func clocksThatDisagreeDontMatter() {
        // The iPad's clock runs ten minutes behind the iPhone's: its new page carries an earlier time than
        // the iPhone place it settled with, and is still a move.
        let mark = FolderSyncMark(others: ["pad": seen(0.3, at: 600)], local: seen(0.3, at: 600))
        let pad = place(0.4, at: 100, on: "iPad")
        #expect(FolderPlaces.settle(["pad": pad], local: seen(0.3, at: 600), mark: mark) == .takeRemote(pad))
    }

    @Test func aDeviceSeenForTheFirstTimeMovedOnlyIfItsPlaceIsNewer() {
        // The iPad read alone to 0.6; an iPhone joins the folder with a month-old 0.2 of its own.
        let mark = FolderSyncMark(others: [:], local: seen(0.6, at: 1000))
        #expect(FolderPlaces.settle(["phone": place(0.2, at: -2_600_000)], local: seen(0.6, at: 1000), mark: mark) == .keepLocal)
        let fresh = place(0.7, at: 2000)
        #expect(FolderPlaces.settle(["phone": fresh], local: seen(0.6, at: 1000), mark: mark) == .takeRemote(fresh))
    }

    @Test func ofSeveralDevicesTheNewestMoveIsTaken() {
        let mark = FolderSyncMark(others: ["phone": seen(0.2, at: 10), "pad": seen(0.2, at: 10)], local: seen(0.2, at: 10))
        let pad = place(0.3, at: 50, on: "iPad"), phone = place(0.4, at: 40)
        #expect(FolderPlaces.settle(["phone": phone, "pad": pad], local: seen(0.2, at: 10), mark: mark) == .takeRemote(pad))
        // One that didn't move since the mark is no newer for being listed.
        #expect(FolderPlaces.settle(["phone": place(0.9, at: 100), "pad": pad], local: seen(0.2, at: 10),
                                    mark: FolderSyncMark(others: ["phone": seen(0.9, at: 100), "pad": seen(0.2, at: 10)], local: seen(0.2, at: 10)))
                == .takeRemote(pad))
    }

    @Test func timesKeepTheirFractionsOfASecond() throws {
        let file = FolderPlaceFile(device: "iPhone", places: ["d1": place(0.4, at: 10.25)])
        let read = try FolderPlaces.decode(FolderPlaces.encode(file))
        #expect(abs(try #require(read.places["d1"]).updated.timeIntervalSince(at(10.25))) < 0.002)
        let older = try FolderPlaces.decode(Data(#"{"device":"iPad","places":{"d1":{"device":"iPad","locator":"{}","progression":0.1,"updated":"2027-01-15T08:00:00Z"}},"version":1}"#.utf8))
        #expect(older.places["d1"]?.progression == 0.1)
    }

    @Test func aPlacesFileICloudHasNotDownloadedIsStillFound() {
        #expect(FolderPlaces.placesFile(listedAs: "places-A1B2.json") == "places-A1B2.json")
        #expect(FolderPlaces.placesFile(listedAs: ".places-A1B2.json.icloud") == "places-A1B2.json")
        #expect(FolderPlaces.placesFile(listedAs: ".places-A1B2 2.json.icloud") == nil)
        #expect(FolderPlaces.placesFile(listedAs: ".notes.json.icloud") == nil)
        #expect(FolderPlaces.placesFile(listedAs: "places-A1B2.json.icloud") == nil)
    }

    @Test func aDamagedFileIsSkippedNotFatal() {
        #expect((try? FolderPlaces.decode(Data("{not json".utf8))) == nil)
        let good = FolderPlaceFile(device: "iPhone", places: ["d1": place(0.3, at: 1)])
        let read = FolderPlaces.decodeAll([Data("{bad".utf8), try! FolderPlaces.encode(good)])
        #expect(read == [good])
    }

    @Test func recordingAPlaceKeepsTheOthers() {
        var file = FolderPlaceFile(device: "iPhone", places: ["d1": place(0.3, at: 1)])
        file.record(place(0.6, at: 9), for: "d2")
        file.record(place(0.4, at: 5), for: "d1")
        #expect(file.places.count == 2)
        #expect(file.places["d1"]?.progression == 0.4)
    }
}

/// What has changed in the folder since the last look, so unchanged books are never read again.
@Suite struct FolderIndexTests {
    @Test func onlyNewAndChangedFilesAreLookedAt() {
        let before = FolderIndex(stamps: ["Emma.epub": .init(size: 100, modified: 1), "Dracula.epub": .init(size: 200, modified: 2)])
        let now: [String: FolderIndex.Stamp] = [
            "Emma.epub": .init(size: 100, modified: 1),
            "Dracula.epub": .init(size: 210, modified: 3),
            "More/Persuasion.epub": .init(size: 50, modified: 4),
        ]
        #expect(before.changed(in: now) == ["Dracula.epub", "More/Persuasion.epub"])
    }

    @Test func anEmptyIndexLooksAtEverything() {
        let now: [String: FolderIndex.Stamp] = ["b.epub": .init(size: 1, modified: 1), "a.epub": .init(size: 1, modified: 1)]
        #expect(FolderIndex().changed(in: now) == ["a.epub", "b.epub"])
    }
}
