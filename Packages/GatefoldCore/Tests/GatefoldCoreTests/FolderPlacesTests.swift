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

    @Test func aNewerPlaceFromAnotherDeviceIsTaken() {
        let remote = place(0.5, at: 20, on: "iPad")
        #expect(FolderPlaces.take(remote, overLocalUpdated: t0.addingTimeInterval(10), localProgression: 0.2) == remote)
        #expect(FolderPlaces.take(remote, overLocalUpdated: nil, localProgression: 0) == remote)
    }

    @Test func anOlderOrSamePlaceIsLeftAlone() {
        let remote = place(0.5, at: 20, on: "iPad")
        #expect(FolderPlaces.take(remote, overLocalUpdated: t0.addingTimeInterval(30), localProgression: 0.2) == nil)
        // The place this device wrote itself, coming back through the folder.
        #expect(FolderPlaces.take(remote, overLocalUpdated: t0.addingTimeInterval(20), localProgression: 0.5) == nil)
        #expect(FolderPlaces.take(nil, overLocalUpdated: nil, localProgression: 0) == nil)
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
