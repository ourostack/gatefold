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
