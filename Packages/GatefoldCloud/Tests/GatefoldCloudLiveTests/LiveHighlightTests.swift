#if os(macOS)
import Foundation
import Testing
@testable import GatefoldCloud

/// The highlights round trip with the app, on test account 1's Frankenstein. Off unless
/// `GATEFOLD_LIVE=1` and `GATEFOLD_LIVE_HIGHLIGHTS` names a step; the driver runs them around the
/// app's live UI test:
///
/// - `seed`: writes a note through the API (the app must then draw it). Its uuid and marker go to
///   `GATEFOLD_LIVE_STATE` (a JSON file) for the later steps.
/// - `verify`: finds the highlight the app made (created after the seed, not the seed) and checks its
///   two CFIs name its words in the book.
/// - `cleanup`: deletes the seed and every highlight made since it, leaving older notes alone.
@Suite("Live highlights round trip", .serialized, .enabled(if: Live.enabled && LiveHighlights.step != nil))
struct LiveHighlightTests {
    @Test func step() async throws {
        let cloud = try await Live.signedIn(1)
        let book = try #require(try await cloud.library().first { $0.fastHash == Live.frankenstein })
        let mapper = try Live.mapper(forEPUB: try await cloud.download(book))
        let before = try await cloud.annotations(for: book)
        Live.log("highlights: \(before.count) annotations on \(book.title) before step \(LiveHighlights.step ?? "")")

        switch LiveHighlights.step {
        case "seed":
            let marker = "Gatefold live \(UUID().uuidString.prefix(6))"
            var found: AnnotationRange?
            for item in mapper.spine.items where found == nil {
                found = await mapper.range(href: item.href, highlight: "My ancestors had been for many years counsellors and syndics",
                                           before: "that republic. ", after: ", and my father", progression: 0)
            }
            let range = try #require(found, "the passage is in the book")
            let seededAt = Date().addingTimeInterval(-2)
            let note = CloudAnnotation.highlight(range, color: .cyan, note: "\(marker): written through the Cloud API, drawn by Gatefold.", at: seededAt)
            await cloud.save(note, for: book)
            await cloud.flushOutbox()
            #expect(await cloud.pendingChanges() == 0)
            let saved = try #require(try await cloud.annotations(for: book).first { $0.noteText?.hasPrefix(marker) == true })
            let uuid = try #require(saved.uuid)
            Live.log("seeded note \(uuid) on \"\(saved.quotation?.value.text ?? "")\" begin=\(saved.quotation?.value.begin ?? "")")
            try LiveHighlights.save(.init(seedUUID: uuid, marker: marker, seededAt: seededAt))

        case "verify":
            let state = try LiveHighlights.load()
            let made = before.filter { $0.uuid != state.seedUUID && ($0.mark?.value.created ?? .distantPast) > state.seededAt }
            Live.log("verify: \(made.count) highlight(s) made since the seed")
            let mine = try #require(made.first, "the app's highlight reached the Cloud")
            let range = try #require(await mapper.range(for: mine), "its anchors resolve in the book")
            let quotation = try #require(mine.quotation?.value)
            Live.log("app highlight \(mine.uuid ?? "") kind=\(mine.kind.value.wireValue) text=\"\(quotation.text)\" begin=\(quotation.begin) end=\(quotation.end)")
            #expect(range.displayText == quotation.text)
            #expect(range.begin.description == EPUBCFI(quotation.begin)?.description, "found by its CFIs, not by searching")
            #expect(range.end.description == EPUBCFI(quotation.end)?.description)
            #expect(mine.anchorStyle == .web)

        case "cleanup":
            let state = try LiveHighlights.load()
            let ours = before.filter { $0.uuid == state.seedUUID || ($0.mark?.value.created ?? .distantPast) > state.seededAt }
            for a in ours { await cloud.deleteAnnotation(a, for: book) }
            await cloud.flushOutbox()
            let after = try await cloud.annotations(for: book)
            Live.log("cleanup: deleted \(ours.count); \(after.count) left (were \(before.count))")
            #expect(after.count == before.count - ours.count)
            #expect(!after.contains { a in ours.contains { $0.uuid == a.uuid } })

        default:
            Issue.record("unknown step")
        }
    }
}

enum LiveHighlights {
    static var step: String? { ProcessInfo.processInfo.environment["GATEFOLD_LIVE_HIGHLIGHTS"] }

    struct State: Codable {
        var seedUUID: String
        var marker: String
        var seededAt: Date
    }

    static var stateFile: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["GATEFOLD_LIVE_STATE"] ?? NSTemporaryDirectory() + "gatefold-live-highlights.json")
    }

    static func save(_ state: State) throws { try JSONEncoder().encode(state).write(to: stateFile) }
    static func load() throws -> State { try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile)) }
}
#endif
