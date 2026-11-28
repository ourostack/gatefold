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

/// A square button's or badge's squircle, never a circle (Ari, 2026-11-20: "squircle ONLY"). A continuous corner
/// reaches 1.528 times its radius along each edge, so one of half the side closes the square into a circle; this one
/// reaches half the side, as web's `corner-shape: squircle` box does (Ouro UI for Apple's `OuroChoiceMetrics.boxRadius`).
struct Squircle: Shape {
    static let continuousCornerReach: CGFloat = 1.528
    /// The corner radius of a squircle `side` points square.
    static func radius(side: CGFloat) -> CGFloat { side / 2 / continuousCornerReach }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: Self.radius(side: min(rect.width, rect.height)), style: .continuous).path(in: rect)
    }
}

/// A book's cover, a squircle: continuous corners, tighter at the spine (the leading edge) than at the fore-edge, as a
/// bound book's are. Every cover Gatefold shows, made or real, is clipped to it: on the shelf, in a catalog row, and on
/// the reader's opening and end leaf. Ouro UI has no cover radius of its own, so this is the one.
struct CoverShape: Shape {
    static let spine: CGFloat = 3
    static let foreEdge: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let (spine, fore) = (Self.spine, Self.foreEdge)
        return UnevenRoundedRectangle(topLeadingRadius: spine, bottomLeadingRadius: spine, bottomTrailingRadius: fore, topTrailingRadius: fore, style: .continuous)
            .path(in: rect)
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
    /// UI tests only: the hidden posture switches at the page's top centre. Only a test that walks the
    /// postures asks for them: anywhere else a tap in the page's top margin (a review driver's, gatefold#303)
    /// landed on the spread switch and laid a one-page screen out as two columns for the rest of the open.
    static var postureSwitches: Bool { isUITest && defaults.bool(forKey: "GatefoldPostureSwitches") }
    /// UI tests only: `reader.columns` reports the web view's own count of the text columns on screen.
    static var columnsProbe: Bool { isUITest && defaults.bool(forKey: "GatefoldColumnsProbe") }
    /// UI tests only: the reader is told of a status column at its top trailing corner (144 x 82 pt) while the status
    /// bar is up, and of nothing covered while it is hidden, in place of the screen's own report: what the open Duo
    /// held upright reports, so the reader's answer to it is tested without a hinge (`DuoLayoutUITests`).
    static var fakeStatusColumn: Bool { isUITest && defaults.bool(forKey: "GatefoldStatusColumn") }
    /// UI tests only: `reader.lineFrames` lists where every line of text on screen stands, in window points.
    static var lineFramesProbe: Bool { isUITest && defaults.bool(forKey: "GatefoldLineFramesProbe") }
    static var resetState: Bool { defaults.bool(forKey: "GatefoldReset") }
    static var skipWelcome: Bool { defaults.bool(forKey: "GatefoldSkipWelcome") }
    /// Measure a cold open: no book is opened ahead of the tap and WebKit isn't started early. Also the
    /// shelf's screenshot, whose CI simulator stopped answering under the hidden pages' WebKit (gatefold#150).
    static var noWarm: Bool { defaults.bool(forKey: "GatefoldNoWarm") }
    /// Films only: the spread's pages stay unpainted for this many seconds as the unfold swings, as on
    /// a busy device, to show the old page holding until they paint.
    /// Tests only: every reflow's restore hangs after laying out, as a cold iPad's could; the page must still show.
    static var stallReflow: Bool { defaults.bool(forKey: "GatefoldStallReflow") }
    /// Tests only: the first reflow after his first move waits 120 s for its page to answer its first script, as
    /// CI's landscape spread did while its chapter loaded (gatefold#94, #133); every restore of it waits.
    static var slowRestorePage: Bool { isUITest && defaults.bool(forKey: "GatefoldSlowRestorePage") }
    /// Tests only: a new column count reaches Readium only once the reflow's restore has finished, so Readium lays
    /// the page out again after the restore's verdict every time, as CI's loaded iPad did turned back upright: it
    /// kept its own place, a page before or after his (merge-queue runs 44355208879, 44371614305 and 44378147938,
    /// gatefold#482).
    static var lateColumns: Bool { isUITest && defaults.bool(forKey: "GatefoldLateColumns") }
    /// Tests only, with `slowRestorePage`: the page shown unsettled is noted as Readium names it and never by
    /// its words, as on a device whose page scripts wait on the stalled install too (gatefold#133).
    static var shownPageWithoutWords: Bool { isUITest && defaults.bool(forKey: "GatefoldShownPageWithoutWords") }
    /// Tests only, with `shownPageWithoutWords`: the page shown unsettled is noted at the place his last write
    /// kept, as when Readium reports no new location while the restore stalls (CI 43075159905, gatefold#133);
    /// otherwise the runner's layout decides whether it is that place or the boundary before it.
    static var shownPageAtHisPlace: Bool { shownPageWithoutWords && defaults.bool(forKey: "GatefoldShownPageAtHisPlace") }
    /// Tests only: the page answers none of the app's scripts for this many looks (50 ms each) after the reader
    /// opens, as CI's starved iPad did for over 14 s after a reopen's chapter loaded (run 43291536110, gatefold#310).
    static var stallOpenScriptsLooks: Int? {
        guard isUITest, defaults.object(forKey: "GatefoldStallOpenScripts") != nil else { return nil }
        return defaults.integer(forKey: "GatefoldStallOpenScripts")
    }
    /// Tests only: the reading order's chapter at this index never answers its counter's first look, as a counter
    /// on CI's starved iPad stopped hearing back mid-count and Emma was never counted at the larger size
    /// (run 43462511882, gatefold#378). It answers again once that counter is taken out of the reader.
    static var stallCounterChapter: Int? {
        guard isUITest, defaults.object(forKey: "GatefoldStallCounterChapter") != nil else { return nil }
        return defaults.integer(forKey: "GatefoldStallCounterChapter")
    }
    /// Tests only, with `shownPageWithoutWords`: at the watchdog the page's span on screen goes unread and Readium
    /// still names the page from before the rotation, his kept place, as on CI's runs 43321734349 and 43370826599
    /// (gatefold#346); unlike `shownPageAtHisPlace`, the screen can be read again as he leaves.
    static var shownSpanLate: Bool { shownPageWithoutWords && defaults.bool(forKey: "GatefoldShownSpanLate") }
    /// Tests only: a book opened on a place with no words opens on its chapter's start, as a reopen whose
    /// stalled restore settled there did on CI (gatefold#250); the saved place itself is unchanged.
    static var reopenOnChapterStart: Bool { isUITest && defaults.bool(forKey: "GatefoldReopenOnChapterStart") }
    /// Tests only: a book opened on a place with his words is handed to Readium at its chapter's start, so only the
    /// open's settle on his words can bring him back, as when CI's starved iPad put a reopen 6 pages before his
    /// words (gatefold#373); the saved place itself is unchanged.
    static var reopenOffHisWords: Bool { isUITest && defaults.bool(forKey: "GatefoldReopenOffHisWords") }
    /// Debug only: a jump's chapter counts as still loading (Readium's spinner up) for this many looks,
    /// so a test can hold the load open as a slow device does and watch the veil (#38).
    static var holdChapterLoadLooks: Int? { defaults.object(forKey: "GatefoldHoldChapterLoad") == nil ? nil : defaults.integer(forKey: "GatefoldHoldChapterLoad") }
    /// UI tests only: a jump of his to a place (the scrubber) is never sent to the page, as a chapter that
    /// never finishes loading: Readium never reports it, and he leaves on the page before (gatefold#279).
    static var holdJumpSends: Bool { isUITest && defaults.bool(forKey: "GatefoldHoldJumpSends") }
    /// UI tests only: a turn's place write never lands (it holds after reading his words, before it maps its
    /// position), as on a device that suspends or ends Gatefold a moment after he leaves, before the write it
    /// had under way lands (gatefold#301). Other writes (the launch jump's) land as ever.
    static var holdTurnWrites: Bool { isUITest && defaults.bool(forKey: "GatefoldHoldTurnWrites") }
    /// UI tests only: a tap's turn holds this many seconds once Readium is on the page beneath, before its leaf
    /// falls and it lands, so a turn of the iPad straight after the tap always begins under the turn (gatefold#534).
    static var holdTapTurnLanding: Double? {
        guard isUITest, defaults.object(forKey: "GatefoldHoldTapTurnLanding") != nil else { return nil }
        return defaults.double(forKey: "GatefoldHoldTapTurnLanding")
    }
    /// UI tests only: the leave's ordinary place write never lands (it holds before it maps its position), as
    /// when the jump's chapter still loading holds that write's read of the page until iOS has ended Gatefold
    /// (gatefold#309). Only what leaving writes at once reaches the reopen.
    static var holdLeaveWrites: Bool { isUITest && defaults.bool(forKey: "GatefoldHoldLeaveWrites") }
    /// Debug only: Back's first this many sends are taken at their chapter's start, the chapter still
    /// loading meanwhile, as a web view still loading takes a jump (gatefold#170). Counted in sends, not
    /// looks, so a Back that stops sending stays short. Armed once per launch, by its first Back. The rest
    /// go once the trip has waited on the load past `JumpLanding.reads`, however that waiting came.
    static var holdBackSends: Int? {
        #if DEBUG
        defaults.object(forKey: "GatefoldHoldBackSends") == nil ? nil : defaults.integer(forKey: "GatefoldHoldBackSends")
        #else
        nil
        #endif
    }
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
    /// UI tests: a Contents jump never comes back, a chapter load that never ends (gatefold#173).
    static var hangLinkJumps: Bool {
        #if DEBUG
        defaults.bool(forKey: "GatefoldHangLinkJumps")
        #else
        false
        #endif
    }
    /// Tests only: the first page counts as still loading, however long he takes, until Catch up is taken, so a
    /// tap over the opening cover is judged while the page loads (gatefold#277; a hold in looks is spent by
    /// every wait that reads it, and ran out before a slow runner's tap).
    static var holdOpeningLoadUntilCatchUp: Bool {
        #if DEBUG
        isUITest && defaults.bool(forKey: "GatefoldHoldOpeningLoadUntilCatchUp")
        #else
        false
        #endif
    }
    /// Tests only: the first page counts as still loading until the page beneath has reported its words, the
    /// test has read the screen a few times since, and for this many looks after, so the opening cover stays up
    /// as it does on a slow device or a stuck load (#94), and a test can tap through it (#104).
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
    /// UI tests: sample books (resource names, comma-separated) arrive once the app has started, as if chosen in
    /// Files, so the shelf's arrival note shows without the picker.
    static var arrive: [String]? {
        guard isUITest, let names = defaults.string(forKey: "GatefoldArrive") else { return nil }
        return names.split(separator: ",").map(String.init)
    }
    /// UI tests: the arrival note stays until closed, so a slow runner still finds it.
    static var holdNotes: Bool { isUITest && defaults.bool(forKey: "GatefoldHoldNotes") }
    /// How long after the start they arrive (`GatefoldArriveAfter`, seconds), so a test can be watching first.
    static var arriveAfter: Double { defaults.double(forKey: "GatefoldArriveAfter") }
    /// UI tests: the shelf's on-device count never opens the book asked for, as it failed to on CI (gatefold#432), so
    /// only the library's word that the book landed can open it (`AskedBookOpensUITests`).
    static var missCountOpen: Bool { defaults.bool(forKey: "GatefoldMissCountOpen") }
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
