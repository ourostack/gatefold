import GatefoldCore
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let c = ThemePalette.components(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: opacity)
    }

    /// The ribbon: Gatefold's one accent, the colour of a silk bookmark.
    static let ribbon = Color("AccentColor")
    /// Labels on a ribbon-coloured fill: white on the light ribbon, ink on the dark one (4.5:1 both).
    static let onRibbon = Color(light: Brand.light.onRibbon, dark: Brand.dark.onRibbon)
    /// The room: plain white by day, true black by night, so the covers are the only colour on screen.
    static let paper = Color(light: 0xFFFFFF, dark: 0x000000)
    static let ink = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    /// Secondary words: neutral grey (5.1:1 light, 7.3:1 dark; deeper under Increase Contrast).
    static let secondaryInk = Color(light: 0x6E6E73, dark: 0x98989D, highContrastLight: 0x515154, highContrastDark: 0xAEAEB2)
    /// A step of structure without a warm pixel: inset fields, empty-cover cloth, grouped rows.
    static let surface = Color(light: 0xF2F2F7, dark: 0x1C1C1E)
    /// A line instead of a box.
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08) })

    init(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil) {
        self.init(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            let isDark = traits.userInterfaceStyle == .dark
            let hex = isDark ? (high ? highContrastDark ?? dark : dark) : (high ? highContrastLight ?? light : light)
            let c = ThemePalette.components(hex)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
}

extension ReaderTheme {
    var background: Color { Color(hex: palette.background) }
    var text: Color { Color(hex: palette.text) }
    var accent: Color { Color(hex: palette.accent) }
    /// Running heads and page numbers.
    var head: Color { Color(hex: palette.head) }
    var uiBackground: UIColor {
        let c = ThemePalette.components(palette.background)
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    var colorScheme: ColorScheme { palette.isDark ? .dark : .light }
    /// Labels on an accent-filled button: white or ink, whichever reads better on this accent.
    var onAccent: Color { Color(hex: palette.onAccent) }
}

extension EnvironmentValues {
    /// The reader's glass is tinted with the page colour, so it stays calm over text.
    @Entry var glassTint: Color? = nil
}

extension View {
    /// Liquid Glass, tinted when the reader asks for it.
    func readerGlass<S: Shape>(_ tint: Color?, interactive: Bool = false, in shape: S) -> some View {
        let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
        return glassEffect(interactive ? base.interactive() : base, in: shape)
    }
}

extension Font {
    /// Chrome titles: SF, like the rest of the room. Serif lives in the book.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .default, weight: weight)
    }
    /// The one serif moment: the Gatefold wordmark and titles printed on generated covers (New York).
    static func wordmark(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Timing shared by every transition, so the app moves with one hand.
enum Motion {
    static let open = Animation.spring(duration: 0.35, bounce: 0)
    static let chrome = Animation.easeOut(duration: 0.2)
    static let reflow = Animation.easeInOut(duration: 0.25)
    static let banner = Animation.spring(duration: 0.45, bounce: 0.18)
}

/// The UI-test and screenshot switches. All DEBUG-only except reading defaults that are harmless.
enum LaunchOptions {
    private static var defaults: UserDefaults { .standard }

    static var isUITest: Bool { defaults.bool(forKey: "GatefoldUITest") }
    static var resetState: Bool { defaults.bool(forKey: "GatefoldReset") }
    static var skipWelcome: Bool { defaults.bool(forKey: "GatefoldSkipWelcome") }
    /// Measure a cold open: no book is opened ahead of the tap.
    static var noWarm: Bool { defaults.bool(forKey: "GatefoldNoWarm") }
    /// Films only: the spread's pages stay unpainted for this many seconds as the unfold swings, as on
    /// a busy device, to show the old page holding until they paint.
    /// Tests only: every reflow's restore hangs after laying out, as a cold iPad's could; the page must still show.
    static var stallReflow: Bool { defaults.bool(forKey: "GatefoldStallReflow") }
    /// Debug only: a jump's chapter counts as still loading (Readium's spinner up) for this many looks,
    /// so a test can hold the load open as a slow device does and watch the veil (#38).
    static var holdChapterLoadLooks: Int? { defaults.object(forKey: "GatefoldHoldChapterLoad") == nil ? nil : defaults.integer(forKey: "GatefoldHoldChapterLoad") }
    /// Debug only: when a jump starts, the page it leaves counts as still loading (Readium's spinner
    /// up) for this many looks, as a page still loading on a slow device does (gatefold#73).
    static var holdOldPageLoadLooks: Int? {
        #if DEBUG
        defaults.object(forKey: "GatefoldHoldOldPageLoad") == nil ? nil : defaults.integer(forKey: "GatefoldHoldOldPageLoad")
        #else
        nil
        #endif
    }
    /// Tests only: how many counters count pages behind the page (0 counts none), for an A/B of what
    /// counting costs a turn.
    static var counters: Int? {
        #if DEBUG
        defaults.object(forKey: "GatefoldCounters") == nil ? nil : defaults.integer(forKey: "GatefoldCounters")
        #else
        nil
        #endif
    }
    /// Tests only: the first page counts as still loading for this many looks, so the opening cover
    /// stays up as it does on a slow device or a stuck load (#94), and a test can tap through it (#104).
    /// UI tests: a Contents jump never comes back, a chapter load that never ends (gatefold#173).
    static var hangLinkJumps: Bool {
        #if DEBUG
        defaults.bool(forKey: "GatefoldHangLinkJumps")
        #else
        false
        #endif
    }
    static var holdOpeningLoadLooks: Int? { defaults.object(forKey: "GatefoldHoldOpeningLoad") == nil ? nil : defaults.integer(forKey: "GatefoldHoldOpeningLoad") }
    /// Tests only: seconds an unanswered offer waits before it folds into its tab (10 by default), so
    /// a test on a slow host can tap Catch up without racing the fold.
    static var offerFoldSeconds: Double {
        #if DEBUG
        defaults.object(forKey: "GatefoldOfferFoldSeconds") == nil ? 10 : defaults.double(forKey: "GatefoldOfferFoldSeconds")
        #else
        10
        #endif
    }
    static var unfoldPaintDelay: Double? { defaults.object(forKey: "GatefoldUnfoldPaintDelay") == nil ? nil : defaults.double(forKey: "GatefoldUnfoldPaintDelay") }
    /// Book IDs to open and close one after another, as taps would (see `RootView.openTour`).
    /// Seconds an open tour rests on the shelf between books (the warm books reopen meanwhile).
    /// Seconds after launch before an open tour's first tap (default 8: the warm books are ready).
    static var tourDelay: Double { defaults.object(forKey: "GatefoldTourDelay") == nil ? 8 : defaults.double(forKey: "GatefoldTourDelay") }
    static var tourRest: Double { defaults.object(forKey: "GatefoldTourRest") == nil ? 3 : defaults.double(forKey: "GatefoldTourRest") }
    static var openTour: [String]? { defaults.string(forKey: "GatefoldOpenTour").map { $0.split(separator: ",").map(String.init) } }
    /// Use the in-memory `FakeSyncService` (bundled public-domain books) instead of PocketBook Cloud.
    /// For previews, UI tests and screenshots; a real launch always talks to the Cloud.
    /// `-GatefoldSignedIn` means "a fake account is already signed in", so it implies the fake too.
    static var fakeCloud: Bool { defaults.bool(forKey: "GatefoldFakeCloud") || signedIn }
    /// Fake Cloud only: start signed in.
    static var signedIn: Bool { defaults.bool(forKey: "GatefoldSignedIn") }
    static var openBook: String? { defaults.string(forKey: "GatefoldOpenBook") }
    /// Reopening the last book at launch. UI tests and the open tours start from the shelf unless they ask.
    static var allowsReopen: Bool {
        defaults.bool(forKey: "GatefoldAllowReopen") || (!isUITest && defaults.object(forKey: "GatefoldOpenTour") == nil)
    }
    /// Tests: the first launch's type size, in place of the one Dynamic Type gives.
    static var fontScale: Double? { defaults.object(forKey: "GatefoldFontScale") == nil ? nil : defaults.double(forKey: "GatefoldFontScale") }
    #if DEBUG
    /// The launch jump's key is this marker's first 12 bytes (`-GatefoldGoTo`). Swift keeps literals of
    /// 15 bytes or fewer inline, out of reach of `strings`, so the key alone can't be found in a binary;
    /// app.yml's Release check looks for this marker instead.
    private static let goToMarker = "GatefoldGoTo/test-only-launch-jump"
    #endif
    /// Tests only: a launch jump. Compiled out of Release, so a shipped app can never move his place by itself.
    static var goTo: Double? {
        #if DEBUG
        let key = String(goToMarker.prefix(12))
        return defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
        #else
        return nil
        #endif
    }
    static var forcedPosture: Posture? { defaults.string(forKey: "GatefoldForcePosture").flatMap(Posture.init(rawValue:)) }
    /// Tests: every book shows its page numbers, position and pages left (all off by default).
    static var pageFurniture: Bool { defaults.bool(forKey: "GatefoldPageFurniture") }
    static var theme: ReaderTheme? { defaults.string(forKey: "GatefoldTheme").flatMap(ReaderTheme.init(rawValue:)) }
    /// Tests: every book turns its pages this way.
    static var pageTurn: PageTurnStyle? { defaults.string(forKey: "GatefoldPageTurn").flatMap(PageTurnStyle.init(rawValue:)) }
    static var showChrome: Bool { defaults.bool(forKey: "GatefoldShowChrome") }
    static var noLatency: Bool { defaults.bool(forKey: "GatefoldNoLatency") }
    static var downloadAll: Bool { defaults.bool(forKey: "GatefoldDownloadAll") }
    static var sheet: String? { defaults.string(forKey: "GatefoldSheet") }
    /// Screenshots and UI tests: switch the forced posture to `GatefoldFlipTo` (default spread) after
    /// this many seconds, and back after `GatefoldFlipBackAfter` more, to film the unfold.
    static var flipAfter: Double? { defaults.object(forKey: "GatefoldFlipAfter") == nil ? nil : defaults.double(forKey: "GatefoldFlipAfter") }
    static var flipTo: Posture { defaults.string(forKey: "GatefoldFlipTo").flatMap(Posture.init(rawValue:)) ?? .spread }
    /// DEBUG films: turn the posture every this many seconds (folded → spread → tabletop → folded).
    static var postureEvery: Double? { defaults.object(forKey: "GatefoldPostureEvery") == nil ? nil : defaults.double(forKey: "GatefoldPostureEvery") }
    static var flipBackAfter: Double? { defaults.object(forKey: "GatefoldFlipBackAfter") == nil ? nil : defaults.double(forKey: "GatefoldFlipBackAfter") }
    /// Screenshots: open the end leaf as if the last page had been turned.
    static var showEnd: Bool { defaults.bool(forKey: "GatefoldShowEnd") }
    /// Fake Cloud only: `empty`, `offline` or `expired`, for screenshots of those states.
    static var fakeScenario: FakeSyncService.Scenario {
        defaults.string(forKey: "GatefoldFakeScenario").flatMap(FakeSyncService.Scenario.init(rawValue:)) ?? .normal
    }
}
