import Testing
@testable import Gatefold

/// The arrival note reports how it ended as counts only: never its words, titles or books.
@Suite struct ArrivalNoteTelemetryTests {
    @Test func theNotesEndIsReportedAsCountsOnly() {
        let properties = GatefoldTelemetry.noteProperties(end: .read, hadRead: true)
        #expect(properties == ["ended": .string("read"), "had_read": .bool(true)])
        for end in [GatefoldTelemetry.NoteEnd.timed, .closed, .read, .replaced] {
            #expect(Set(GatefoldTelemetry.noteProperties(end: end, hadRead: false).keys) == ["ended", "had_read"])
        }
    }
}
