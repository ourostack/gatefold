import Foundation
import GatefoldCore
import Testing

/// Fine-Tune's Justify says what the page does. Off used to mean "the book's own alignment", and a Gutenberg book
/// justifies itself, so every page was justified while the switch read Off (review panel 2026-11-22, *-08 against
/// *-01). The page a reader sees by default is justified, so Justify starts On; Off sets the text ragged.
struct JustifyTruthTests {
    @Test func justifyStartsOnLikeThePage() {
        #expect(ReaderPreferences().justify)
        #expect(PreferencesStore().defaults.justify)
    }

    /// Settings saved before this fix say Off for a page that was justified: once, they read On, so his page looks as
    /// it did and the switch now tells the truth. Nothing else he chose changes.
    @Test func savedOffBecomesOnOnceSoThePageKeepsItsLook() throws {
        var store = PreferencesStore()
        store.updateDefaults { $0.fontScale = 1.4 }
        store.update("a") { $0.margins = .wide }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as! [String: Any]
        var defaults = json["defaults"] as! [String: Any]
        defaults["justify"] = false
        json["defaults"] = defaults
        var perBook = json["perBook"] as! [String: Any]
        var a = perBook["a"] as! [String: Any]
        a["justify"] = false
        perBook["a"] = a
        json["perBook"] = perBook
        json.removeValue(forKey: "alignVersion")
        var old = try JSONDecoder().decode(PreferencesStore.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.defaults.justify, "the premise: saved Off")
        old.adoptTruthfulJustify()
        #expect(old.defaults.justify && old.effective(for: "a").justify)
        #expect(old.defaults.fontScale == 1.4 && old.effective(for: "a").margins == .wide, "his other choices stay")
        // Once only: Off chosen after the move stays Off.
        old.updateDefaults { $0.justify = false }
        old.adoptTruthfulJustify()
        #expect(!old.defaults.justify)
    }
}
