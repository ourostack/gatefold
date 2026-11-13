import Foundation
import GatefoldCloud
import Testing
@testable import Gatefold

/// Since November 2026 PocketBook Cloud turns away every position write (422 "position: File not
/// found.", seen live 2026-11-13). The shelf must never say "In step with your e-reader" over a place
/// the e-reader never got.
@MainActor @Suite(.serialized) struct PlaceRefusedTests {
    let wind = CloudBook(fastHash: "wind", name: "wind.epub", title: "Wind and Truth",
                         position: ReadingPosition(cfi: nil, totalProgression: 0.6, updated: Date(), source: .pocketBookNative))

    private func shelf(root: URL = URL.temporaryDirectory.appending(path: "place-refused-\(UUID().uuidString)")) async -> AppModel {
        let sync = StubSync()
        let app = AppModel(sync: sync, libraryRoot: root)
        await sync.setLibrary(.success([wind]))
        await app.start()
        return app
    }

    @Test func aRefusedPlaceTakesTheShelfOutOfStep() async {
        let app = await shelf()
        #expect(app.library.placesReachEReader)
        await app.apply(.positionRefused(fastHash: "wind"))
        #expect(!app.library.placesReachEReader)
        #expect(app.library.placesNotSent == ["wind"])
    }

    @Test func aPlaceThatLaterLandsPutsItBack() async {
        let app = await shelf()
        await app.apply(.positionRefused(fastHash: "wind"))
        await app.apply(.positionSent(fastHash: "wind"))
        #expect(app.library.placesReachEReader)
    }

    @Test func aRelaunchRemembersThePlaceThatDidntGetThrough() async {
        let root = URL.temporaryDirectory.appending(path: "place-refused-\(UUID().uuidString)")
        let first = await shelf(root: root)
        await first.apply(.positionRefused(fastHash: "wind"))
        let again = await shelf(root: root)
        #expect(!again.library.placesReachEReader)
    }

    @Test func theLineIsInTheReadersWords() {
        let line = LibraryStore.placesNotSentLine
        #expect(line.contains("e-reader"))
        #expect(!line.contains("PocketBook"))
        #expect(!line.lowercased().contains("in step"))
    }
}
