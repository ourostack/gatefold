import Foundation
import Testing
@testable import GatefoldCore

/// Page numbers, the position label and pages left are his choice; he usually prefers them off.
struct PageFurnitureTests {
    @Test func allOffByDefault() {
        let p = ReaderPreferences()
        #expect(!p.showsPageNumbers)
        #expect(!p.showsPositionLabel)
        #expect(!p.showsPagesLeft)
    }

    @Test func choicesRoundTrip() throws {
        var p = ReaderPreferences()
        p.showsPageNumbers = true
        p.showsPagesLeft = true
        let back = try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(back.showsPageNumbers && back.showsPagesLeft && !back.showsPositionLabel)
    }

    /// Settings saved before build 17 have no furniture keys: they keep everything else and read off.
    @Test func olderSettingsKeepTheirLookAndReadOff() throws {
        var old = ReaderPreferences()
        old.fontScale = 1.4
        old.justify = true
        old.theme = .vellum
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for key in ["showsPageNumbers", "showsPositionLabel", "showsPagesLeft"] { json.removeValue(forKey: key) }
        let back = try JSONDecoder().decode(ReaderPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.fontScale == 1.4 && back.justify && back.theme == .vellum)
        #expect(!back.showsPageNumbers && !back.showsPositionLabel && !back.showsPagesLeft)
    }
}
