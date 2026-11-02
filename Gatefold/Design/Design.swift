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
    /// Warm paper, for the welcome and empty states.
    static let paper = Color(light: 0xF6F1E7, dark: 0x1B1A18)
    static let ink = Color(light: 0x23201C, dark: 0xEDE6DA)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let c = ThemePalette.components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
}

extension ReaderTheme {
    var background: Color { Color(hex: palette.background) }
    var text: Color { Color(hex: palette.text) }
    var accent: Color { Color(hex: palette.accent) }
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
    /// Display type: New York, for titles. Books uses SF; serif keeps us our own.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .serif, weight: weight)
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
    /// Use the in-memory `FakeSyncService` (bundled public-domain books) instead of PocketBook Cloud.
    /// For previews, UI tests and screenshots; a real launch always talks to the Cloud.
    /// `-GatefoldSignedIn` means "a fake account is already signed in", so it implies the fake too.
    static var fakeCloud: Bool { defaults.bool(forKey: "GatefoldFakeCloud") || signedIn }
    /// Fake Cloud only: start signed in.
    static var signedIn: Bool { defaults.bool(forKey: "GatefoldSignedIn") }
    static var openBook: String? { defaults.string(forKey: "GatefoldOpenBook") }
    static var goTo: Double? { defaults.object(forKey: "GatefoldGoTo") == nil ? nil : defaults.double(forKey: "GatefoldGoTo") }
    static var forcedPosture: Posture? { defaults.string(forKey: "GatefoldForcePosture").flatMap(Posture.init(rawValue:)) }
    static var theme: ReaderTheme? { defaults.string(forKey: "GatefoldTheme").flatMap(ReaderTheme.init(rawValue:)) }
    static var showChrome: Bool { defaults.bool(forKey: "GatefoldShowChrome") }
    static var noLatency: Bool { defaults.bool(forKey: "GatefoldNoLatency") }
    static var downloadAll: Bool { defaults.bool(forKey: "GatefoldDownloadAll") }
    static var sheet: String? { defaults.string(forKey: "GatefoldSheet") }
    /// Screenshots and UI tests: switch the forced posture to `GatefoldFlipTo` (default spread) after
    /// this many seconds, and back after `GatefoldFlipBackAfter` more, to film the unfold.
    static var flipAfter: Double? { defaults.object(forKey: "GatefoldFlipAfter") == nil ? nil : defaults.double(forKey: "GatefoldFlipAfter") }
    static var flipTo: Posture { defaults.string(forKey: "GatefoldFlipTo").flatMap(Posture.init(rawValue:)) ?? .spread }
    static var flipBackAfter: Double? { defaults.object(forKey: "GatefoldFlipBackAfter") == nil ? nil : defaults.double(forKey: "GatefoldFlipBackAfter") }
    /// Screenshots: open the end leaf as if the last page had been turned.
    static var showEnd: Bool { defaults.bool(forKey: "GatefoldShowEnd") }
    /// Fake Cloud only: `empty`, `offline` or `expired`, for screenshots of those states.
    static var fakeScenario: FakeSyncService.Scenario {
        defaults.string(forKey: "GatefoldFakeScenario").flatMap(FakeSyncService.Scenario.init(rawValue:)) ?? .normal
    }
}
