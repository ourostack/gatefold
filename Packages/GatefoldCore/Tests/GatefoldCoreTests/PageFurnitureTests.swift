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

    /// Furniture is the reader's, not a book's look: turning page numbers on in one book turns them on
    /// in every book, and leaves that book following his defaults.
    @Test func aToggleInOneBookAppliesToEveryBook() {
        var store = PreferencesStore()
        store.update("a") { $0.showsPageNumbers = true }
        #expect(store.effective(for: "a").showsPageNumbers)
        #expect(store.effective(for: "b").showsPageNumbers, "another book has them on too")
        #expect(store.followsDefault("a"), "a furniture toggle doesn't make the book differ")
        store.update("b") { $0.showsPageNumbers = false }
        #expect(!store.effective(for: "a").showsPageNumbers, "and off is off everywhere")
    }

    /// A book's own look stays its own alongside global furniture.
    @Test func aBooksLookStaysItsOwn() {
        var store = PreferencesStore()
        store.update("a") { $0.fontScale = 1.6; $0.showsPagesLeft = true }
        #expect(store.effective(for: "a").fontScale == 1.6)
        #expect(store.effective(for: "b").fontScale != 1.6)
        #expect(store.effective(for: "b").showsPagesLeft)
        #expect(!store.followsDefault("a"))
    }

    /// Build 17 kept furniture per book: a toggle he turned on in any book is on everywhere now.
    @Test func perBookFurnitureFromBuild17BecomesGlobal() throws {
        var store = PreferencesStore()
        store.update("a") { $0.fontScale = 1.6 }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as! [String: Any]
        var perBook = json["perBook"] as! [String: Any]
        var a = perBook["a"] as! [String: Any]
        a["showsPositionLabel"] = true
        perBook["a"] = a
        perBook["c"] = (json["defaults"] as! [String: Any]).merging(["showsPageNumbers": true]) { _, new in new }
        json["perBook"] = perBook
        json.removeValue(forKey: "furnitureVersion")
        var old = try JSONDecoder().decode(PreferencesStore.self, from: JSONSerialization.data(withJSONObject: json))
        old.adoptGlobalFurniture()
        #expect(old.defaults.showsPositionLabel && old.defaults.showsPageNumbers && !old.defaults.showsPagesLeft)
        #expect(old.effective(for: "a").fontScale == 1.6, "his book's look is kept")
        #expect(old.followsDefault("c"), "a book that differed only in furniture follows his defaults again")
        #expect(old.effective(for: "b").showsPageNumbers)
    }
}
