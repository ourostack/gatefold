import Foundation
import Testing
@testable import GatefoldCore

@Suite("Reading preferences, per book or as the default")
struct PreferencesTests {
    @Test func aBookWithoutItsOwnSettingsUsesTheDefault() {
        let store = PreferencesStore()
        #expect(store.effective(for: "moby") == ReaderPreferences())
        #expect(store.followsDefault("moby"))
    }

    @Test func changingOneBookLeavesTheOthersAlone() {
        var store = PreferencesStore()
        store.update("moby") { $0.font = .newYork }
        #expect(store.effective(for: "moby").font == .newYork)
        #expect(store.effective(for: "emma").font == ReaderPreferences().font)
        #expect(!store.followsDefault("moby"))
    }

    @Test func useAsDefaultAppliesThisBooksLookToEveryBook() {
        var store = PreferencesStore()
        store.update("emma") { $0.lineSpacing = .relaxed }
        store.update("moby") {
            $0.font = .iowan
            $0.fontScale = 1.3
            $0.theme = .vellum
        }
        store.useAsDefault(from: "moby")
        #expect(store.defaults.font == .iowan)
        #expect(store.effective(for: "emma").font == .iowan)
        #expect(store.effective(for: "emma").lineSpacing == ReaderPreferences().lineSpacing)
        #expect(store.effective(for: "dracula").theme == .vellum)
        #expect(store.followsDefault("moby"))
        #expect(store.followsDefault("emma"))
    }

    @Test func fontStepsClampAndReportWhetherTheyMoved() {
        var prefs = ReaderPreferences()
        prefs.fontScale = ReaderPreferences.fontScaleRange.upperBound
        let pastTop = prefs.stepFont(up: true)
        #expect(!pastTop)
        prefs.fontScale = ReaderPreferences.fontScaleRange.lowerBound
        let pastBottom = prefs.stepFont(up: false)
        #expect(!pastBottom)
        let up = prefs.stepFont(up: true)
        #expect(up)
        #expect(prefs.fontScale > ReaderPreferences.fontScaleRange.lowerBound)
    }

    @Test func theFirstFontScaleFollowsDynamicType() {
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 3) == 1.0) // Large, the default
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 0) < 1.0)
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 11) <= ReaderPreferences.fontScaleRange.upperBound)
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 11) > 1.5)
    }

    @Test func theStoreRoundTripsThroughJSON() throws {
        var store = PreferencesStore()
        store.update("moby") { $0.pageTurn = .scroll }
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(PreferencesStore.self, from: data)
        #expect(decoded == store)
    }

    @Test func reduceMotionTurnsTheCurlIntoAFade() {
        var prefs = ReaderPreferences()
        prefs.pageTurn = .curl
        #expect(prefs.effectivePageTurn(reduceMotion: true) == .fade)
        #expect(prefs.effectivePageTurn(reduceMotion: false) == .curl)
        prefs.pageTurn = .scroll
        #expect(prefs.effectivePageTurn(reduceMotion: true) == .scroll)
    }

    @Test func themeFollowsTheSystemWhenAsked() {
        var prefs = ReaderPreferences()
        prefs.theme = .vellum
        prefs.darkTheme = .midnight
        prefs.matchSystemAppearance = true
        #expect(prefs.resolvedTheme(systemIsDark: true) == .midnight)
        #expect(prefs.resolvedTheme(systemIsDark: false) == .vellum)
        prefs.matchSystemAppearance = false
        #expect(prefs.resolvedTheme(systemIsDark: true) == .vellum)
    }
}

@Suite("Themes")
struct ThemeTests {
    @Test func thereAreSixThemesAndEachHasItsOwnName() {
        #expect(ReaderTheme.allCases.count == 6)
        #expect(Set(ReaderTheme.allCases.map(\.displayName)).count == 6)
    }

    @Test(arguments: ReaderTheme.allCases)
    func everyThemeReadsAtAAAContrast(theme: ReaderTheme) {
        #expect(theme.palette.contrastRatio >= 7.0, "\(theme) is \(theme.palette.contrastRatio):1")
    }

    @Test func darkThemesAreMarkedDark() {
        #expect(ReaderTheme.midnight.palette.isDark)
        #expect(ReaderTheme.dusk.palette.isDark)
        #expect(!ReaderTheme.daylight.palette.isDark)
    }
}

/// Build 15: the default page matches Apple Books' density, with larger type and outer margins of
/// about 6% of the page. Readers who never changed the size get the new one; a chosen size stays.
@Suite("Page density")
struct PageDensityTests {
    /// The store as build 14 wrote it, without a density version.
    private func savedByBuild14(_ store: PreferencesStore) throws -> PreferencesStore {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as! [String: Any]
        json["densityVersion"] = nil
        return try JSONDecoder().decode(PreferencesStore.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aNewStoreIsAtTheCurrentDensity() {
        var store = PreferencesStore()
        store.adoptCurrentDensity(untouched: 1.0, now: 1.3)
        #expect(store.defaults.fontScale == 1.0, "a fresh store's size is already the new one")
    }

    @Test func classicOnAWidePageKeepsApplesMeasure() {
        // Apple Books' default iPad spread (aris-device/4): text 80.7% of each page's width. Readium's
        // margins are even on both sides, so Classic keeps about 9.6% each side of an iPad page.
        for (page, view) in [(688.0, 1376.0), (597.0, 1194.0), (1024.0, 1024.0), (820.0, 820.0)] {
            let margin = PageMargins.normal.readiumFactor(pageWidth: page, viewWidth: view) * PageMargins.readiumGutter(viewWidth: view)
            let text = (page - 2 * margin) / page
            #expect(abs(text - 0.807) < 0.01, "Classic on a \(page) pt page: text \(text)")
        }
    }

    @Test func classicOnAPhonePageKeepsAboutSixPercentEachSide() {
        for (page, view) in [(466.0, 466.0), (402.0, 402.0), (233.0, 466.0)] {
            let margin = PageMargins.normal.readiumFactor(pageWidth: page, viewWidth: view) * PageMargins.readiumGutter(viewWidth: view)
            #expect(abs(margin / page - 0.06) < 0.002, "Classic on a \(page) pt page: \(margin) pt")
        }
    }

    @Test func theIPadsFirstSizeMatchesApplesLinePitch() {
        // Apple Books' default spread sets a line every 5.7% of the page's width; Gatefold at 1.5
        // measured 4.87%, so Large on the iPad starts at about 1.75 (a line pitch scales with the size).
        #expect(abs(ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: true) - 1.75) < 0.011)
        #expect(ReaderPreferences.initialFontScale(forContentSizeRank: 3, regularWidth: false) == 1.3)
    }

    @Test func slimClassicRoomyStayInOrder() {
        for (page, view) in [(688.0, 1376.0), (402.0, 402.0)] {
            let f = { (m: PageMargins) in m.readiumFactor(pageWidth: page, viewWidth: view) }
            #expect(f(.narrow) < f(.normal))
            #expect(f(.normal) < f(.wide))
        }
        #expect(ReaderPreferences().margins == .normal, "Classic is the default")
    }

    @Test func readiumsGutterFollowsItsBreakpoints() {
        #expect(PageMargins.readiumGutter(viewWidth: 400) == 20)
        #expect(PageMargins.readiumGutter(viewWidth: 600) == 30)
        #expect(PageMargins.readiumGutter(viewWidth: 800) == 40)
        #expect(PageMargins.readiumGutter(viewWidth: 1376) == 50)
    }

    @Test func theFirstSizeIsLargerThanBefore() {
        for rank in 0..<12 {
            for pad in [false, true] {
                let old = ReaderPreferences.legacyInitialFontScale(forContentSizeRank: rank, regularWidth: pad)
                let new = ReaderPreferences.initialFontScale(forContentSizeRank: rank, regularWidth: pad)
                #expect(new > old || new == ReaderPreferences.fontScaleRange.upperBound, "rank \(rank) pad \(pad): \(old) -> \(new)")
                #expect(ReaderPreferences.fontScaleRange.contains(new))
            }
        }
    }

    @Test func anUntouchedSizeMovesToTheNewDefault() throws {
        var first = ReaderPreferences()
        first.fontScale = 1.15
        var store = PreferencesStore(defaults: first)
        store.update("chosen") { $0.fontScale = 1.4 }
        store.update("themed") { $0.theme = .midnight }
        // Saved by build 14: no density version.
        var loaded = try savedByBuild14(store)
        #expect(loaded.densityVersion == nil)
        loaded.adoptCurrentDensity(untouched: 1.15, now: 1.5)
        #expect(loaded.defaults.fontScale == 1.5, "never changed: the new size")
        #expect(loaded.effective(for: "themed").fontScale == 1.5, "a book given only a theme follows")
        #expect(loaded.effective(for: "themed").theme == .midnight)
        #expect(loaded.effective(for: "chosen").fontScale == 1.4, "a size he chose stays his")
        #expect(loaded.densityVersion == PreferencesStore.currentDensity)
        // Once only: a later "untouched" match is his own choice.
        loaded.updateDefaults { $0.fontScale = 1.15 }
        loaded.adoptCurrentDensity(untouched: 1.15, now: 1.5)
        #expect(loaded.defaults.fontScale == 1.15)
    }

    @Test func aChosenMarginStays() throws {
        var prefs = ReaderPreferences()
        prefs.fontScale = 1.0
        prefs.margins = .wide
        var store = try savedByBuild14(PreferencesStore(defaults: prefs))
        store.adoptCurrentDensity(untouched: 1.0, now: 1.3)
        #expect(store.defaults.margins == .wide)
        #expect(store.defaults.fontScale == 1.3)
    }
}
