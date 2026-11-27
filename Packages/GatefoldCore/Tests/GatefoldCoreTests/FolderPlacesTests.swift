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

    @Test func theNewestPlaceForEachBookWinsAcrossDevices() {
        let phone = FolderPlaceFile(device: "iPhone", places: ["d1": place(0.2, at: 10), "d2": place(0.9, at: 50)])
        let pad = FolderPlaceFile(device: "iPad", places: ["d1": place(0.5, at: 20, on: "iPad"), "d2": place(0.1, at: 5, on: "iPad")])
        let newest = FolderPlaces.newest(in: [phone, pad])
        #expect(newest["d1"]?.progression == 0.5)
        #expect(newest["d1"]?.device == "iPad")
        // Newer wins, not further: going back to reread a chapter is a place too.
        #expect(newest["d2"]?.progression == 0.9)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func withNothingSettledYetTheNewerPlaceIsTaken() {
        let remote = place(0.5, at: 20, on: "iPad")
        #expect(FolderPlaces.settle(remote, localUpdated: at(10), localProgression: 0.2, mark: nil) == .takeRemote(remote))
        #expect(FolderPlaces.settle(remote, localUpdated: nil, localProgression: 0, mark: nil) == .takeRemote(remote))
        #expect(FolderPlaces.settle(remote, localUpdated: at(30), localProgression: 0.2, mark: nil) == .keepLocal)
        // The place this device wrote itself, coming back through the folder a fraction older (whole seconds).
        #expect(FolderPlaces.settle(remote, localUpdated: at(20.4), localProgression: 0.5, mark: nil) == .keepLocal)
        #expect(FolderPlaces.settle(nil, localUpdated: nil, localProgression: 0, mark: nil) == .keepLocal)
    }

    @Test func onlyTheOtherDeviceMovedSoItsPlaceIsTakenEvenGoingBack() {
        let mark = FolderSyncMark(remote: at(10), local: at(10))
        // Gone back to reread a chapter on the iPad: a place too.
        let back = place(0.1, at: 60, on: "iPad")
        #expect(FolderPlaces.settle(back, localUpdated: at(10), localProgression: 0.5, mark: mark) == .takeRemote(back))
    }

    @Test func onlyThisDeviceMovedSoItsPlaceStays() {
        let mark = FolderSyncMark(remote: at(10), local: at(10))
        let unchanged = place(0.5, at: 10, on: "iPad")
        #expect(FolderPlaces.settle(unchanged, localUpdated: at(90), localProgression: 0.2, mark: mark) == .keepLocal)
        #expect(FolderPlaces.settle(unchanged, localUpdated: at(10), localProgression: 0.5, mark: mark) == .keepLocal)
    }

    @Test func whenBothMovedTheFurtherPlaceWins() {
        let mark = FolderSyncMark(remote: at(10), local: at(10))
        // The iPhone read on to half way. The iPad, still open at 10 %, turned one page later on: newer,
        // but taking it would send the iPhone back, so the iPhone's place wins on both devices.
        let phone = place(0.5, at: 60, on: "iPhone")
        #expect(FolderPlaces.settle(phone, localUpdated: at(120), localProgression: 0.11, mark: mark) == .takeRemote(phone))
        let stale = place(0.11, at: 120, on: "iPad")
        #expect(FolderPlaces.settle(stale, localUpdated: at(60), localProgression: 0.5, mark: mark) == .keepLocal)
    }

    @Test func aMarkWithNoRemoteYetCountsAnyRemoteAsMoved() {
        let mark = FolderSyncMark(remote: nil, local: at(10))
        let remote = place(0.3, at: 5, on: "iPad")
        #expect(FolderPlaces.settle(remote, localUpdated: at(10), localProgression: 0.2, mark: mark) == .takeRemote(remote))
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
