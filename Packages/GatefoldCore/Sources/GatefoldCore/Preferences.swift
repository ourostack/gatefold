import Foundation

public enum ReaderTheme: String, CaseIterable, Codable, Sendable {
    case daylight, vellum, fog, sage, dusk, midnight

    public var displayName: String {
        switch self {
        case .daylight: "Daylight"
        case .vellum: "Linen"
        case .fog: "Fog"
        case .sage: "Sage"
        case .dusk: "Dusk"
        case .midnight: "Midnight"
        }
    }

    public var palette: ThemePalette {
        switch self {
        case .daylight: ThemePalette(background: 0xFFFFFF, text: 0x1D1D1F, accent: 0x2F5D8A, head: 0x737378)
        case .vellum: ThemePalette(background: 0xF7F5F0, text: 0x2A2927, accent: 0x6E5844, head: 0x6C6B67)
        case .fog: ThemePalette(background: 0xECEDEF, text: 0x1F2328, accent: 0x3B5B7C, head: 0x63666B)
        case .sage: ThemePalette(background: 0xE8ECE6, text: 0x1E2820, accent: 0x46654F, head: 0x5E655E)
        case .dusk: ThemePalette(background: 0x1C1C1E, text: 0xD9D9DE, accent: 0x8DB0DA, head: 0x8E8E93)
        case .midnight: ThemePalette(background: 0x000000, text: 0xB8B8BE, accent: 0x7F9FC7, head: 0x76767C)
        }
    }
}

/// Colours as 0xRRGGBB.
public struct ThemePalette: Equatable, Sendable {
    public var background: UInt32
    public var text: UInt32
    public var accent: UInt32
    /// Running heads and page numbers: quiet grey furniture, at least 4.5:1 on the paper.
    public var head: UInt32

    public init(background: UInt32, text: UInt32, accent: UInt32, head: UInt32? = nil) {
        self.background = background
        self.text = text
        self.accent = accent
        self.head = head ?? text
    }

    public var isDark: Bool { Self.luminance(background) < 0.2 }

    /// WCAG 2 contrast ratio between text and background.
    public var contrastRatio: Double {
        let a = Self.luminance(background), b = Self.luminance(text)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    public static func hexString(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = components(hex)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

public enum ReaderFont: String, CaseIterable, Codable, Sendable {
    /// The publisher's own font.
    case original
    case newYork
    case iowan
    case georgia
    case system

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .newYork: "New York"
        case .iowan: "Iowan"
        case .georgia: "Georgia"
        case .system: "San Francisco"
        }
    }

    /// The CSS font family the web view uses; nil keeps the publisher's.
    public var cssFamily: String? {
        switch self {
        case .original: nil
        case .newYork: "ui-serif"
        case .iowan: "Iowan Old Style"
        case .georgia: "Georgia"
        case .system: "-apple-system"
        }
    }
}

public enum LineSpacing: String, CaseIterable, Codable, Sendable {
    case compact, normal, relaxed
    public var lineHeight: Double {
        switch self {
        case .compact: 1.25
        case .normal: 1.5
        case .relaxed: 1.8
        }
    }
}

public enum PageMargins: String, CaseIterable, Codable, Sendable {
    case narrow, normal, wide
    /// Readium's page-margin multiplier.
    public var factor: Double {
        switch self {
        case .narrow: 0.6
        case .normal: 1.0
        case .wide: 1.6
        }
    }

    /// The share of the page's width kept as margin on each side. Classic, the default, keeps Apple
    /// Books' default measure on a wide page (an iPad's, or each page of its spread): text 80.7% of
    /// the page, measured on aris-device/4, so about 9.6% each side (Readium's two sides are even;
    /// Apple's are about 12.5% outside and 6.8% at the spine). A phone-width page (an iPhone, the
    /// Duo's cover screen) keeps about 6%, so its short line keeps its words. Build 14 gave an iPad
    /// spread about 2%, and its lines ran to the edges.
    public func share(pageWidth: Double) -> Double {
        let wide = pageWidth >= Self.widePage
        switch self {
        case .narrow: return wide ? 0.065 : 0.035
        case .normal: return wide ? 0.0965 : 0.06
        case .wide: return wide ? 0.13 : 0.09
        }
    }

    /// The narrowest page that keeps Apple Books' iPad measure (an 11" iPad's spread page is 597 pt).
    public static let widePage: Double = 560

    /// ReadiumCSS's own page gutter at a web view this wide (its breakpoints at 35, 45 and 75 em).
    public static func readiumGutter(viewWidth: Double) -> Double {
        viewWidth >= 1200 ? 50 : viewWidth >= 720 ? 40 : viewWidth >= 560 ? 30 : 20
    }

    /// Readium's margin multiplier that keeps `share` of a page `pageWidth` wide, in a web view
    /// `viewWidth` wide (a spread's two pages share one).
    public func readiumFactor(pageWidth: Double, viewWidth: Double) -> Double {
        min(4, max(0.2, share(pageWidth: pageWidth) * pageWidth / Self.readiumGutter(viewWidth: viewWidth)))
    }
}

public enum PageTurnStyle: String, CaseIterable, Codable, Sendable {
    case curl, slide, scroll
    /// Only ever the effective style under Reduce Motion; never stored.
    case fade

    public static var choices: [PageTurnStyle] { [.curl, .slide, .scroll] }

    public var displayName: String {
        switch self {
        case .curl: "Curl"
        case .slide: "Slide"
        case .scroll: "Scroll"
        case .fade: "Fade"
        }
    }
}

public struct ReaderPreferences: Codable, Equatable, Sendable {
    public static let fontScaleRange: ClosedRange<Double> = 0.7...2.4
    public static let fontScaleStep = 0.1

    public var theme: ReaderTheme = .daylight
    public var darkTheme: ReaderTheme = .dusk
    public var matchSystemAppearance = true
    public var font: ReaderFont = .original
    public var fontScale = 1.0
    public var lineSpacing: LineSpacing = .normal
    public var margins: PageMargins = .normal
    public var justify = false
    public var pageTurn: PageTurnStyle = .curl
    /// Page furniture, his choice and off unless he turns it on: the number under each page, the
    /// position in the book ("12 of 340") and pages left in the chapter. None of them changes the
    /// layout, so turning one on or off never moves the words.
    public var showsPageNumbers = false
    public var showsPositionLabel = false
    public var showsPagesLeft = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, darkTheme, matchSystemAppearance, font, fontScale, lineSpacing, margins, justify, pageTurn
        case showsPageNumbers, showsPositionLabel, showsPagesLeft
    }

    /// Settings saved by an older build lack newer keys; each missing one takes its default rather
    /// than throwing the whole look away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderPreferences()
        theme = try c.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? d.theme
        darkTheme = try c.decodeIfPresent(ReaderTheme.self, forKey: .darkTheme) ?? d.darkTheme
        matchSystemAppearance = try c.decodeIfPresent(Bool.self, forKey: .matchSystemAppearance) ?? d.matchSystemAppearance
        font = try c.decodeIfPresent(ReaderFont.self, forKey: .font) ?? d.font
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? d.fontScale
        lineSpacing = try c.decodeIfPresent(LineSpacing.self, forKey: .lineSpacing) ?? d.lineSpacing
        margins = try c.decodeIfPresent(PageMargins.self, forKey: .margins) ?? d.margins
        justify = try c.decodeIfPresent(Bool.self, forKey: .justify) ?? d.justify
        pageTurn = try c.decodeIfPresent(PageTurnStyle.self, forKey: .pageTurn) ?? d.pageTurn
        showsPageNumbers = try c.decodeIfPresent(Bool.self, forKey: .showsPageNumbers) ?? false
        showsPositionLabel = try c.decodeIfPresent(Bool.self, forKey: .showsPositionLabel) ?? false
        showsPagesLeft = try c.decodeIfPresent(Bool.self, forKey: .showsPagesLeft) ?? false
    }

    /// Steps the font size; returns false at either end so the caller can skip the haptic.
    @discardableResult
    public mutating func stepFont(up: Bool) -> Bool {
        let next = (fontScale + (up ? Self.fontScaleStep : -Self.fontScaleStep)) * 100
        let clamped = min(Self.fontScaleRange.upperBound, max(Self.fontScaleRange.lowerBound, next.rounded() / 100))
        guard clamped != fontScale else { return false }
        fontScale = clamped
        return true
    }

    public func effectivePageTurn(reduceMotion: Bool) -> PageTurnStyle {
        reduceMotion && pageTurn != .scroll ? .fade : pageTurn
    }

    public func resolvedTheme(systemIsDark: Bool) -> ReaderTheme {
        matchSystemAppearance && systemIsDark ? darkTheme : theme
    }

    /// The first book's font size follows Dynamic Type; after that it's the reader's own.
    /// `rank` counts content sizes from extra small (0) through Large (3) to AX5 (11).
    /// Build 14's sizes; build 15 sets type larger (`densityRaise`).
    public static func initialFontScale(forContentSizeRank rank: Int) -> Double {
        let scales: [Double] = [0.8, 0.9, 0.95, 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 1.9, 2.1, 2.3]
        return scales[min(max(rank, 0), scales.count - 1)]
    }

    /// How much larger build 15 sets the first size than build 14 did. On the iPad it matches Apple
    /// Books' default line pitch (a line every 5.7% of the page's width on aris-device/4; Gatefold at
    /// 1.5 measured 4.87%, so 1.15 × 1.52 ≈ 1.75). A phone has no Apple Books reference yet and takes 1.3.
    public static func densityRaise(regularWidth: Bool) -> Double { regularWidth ? 1.52 : 1.3 }
}

/// Settings for every book, with optional per-book overrides. "Use as default" turns one book's
/// look into everyone's, which Books can't do and PocketBook readers ask for.
public struct PreferencesStore: Codable, Equatable, Sendable {
    public private(set) var defaults: ReaderPreferences
    private var perBook: [String: ReaderPreferences] = [:]
    /// The page density these settings were saved under: nil before build 15, `currentDensity` after.
    public private(set) var densityVersion: Int?

    /// Build 15's denser-to-calmer page: larger first type size.
    public static let currentDensity = 2

    /// Once, for settings saved before build 15: a type size still at the old first size moves to
    /// the new one, so a reader who never changed it gets the new page; a size he chose stays.
    /// (Margins need no move: Classic stays the default and now means about 6% of the page.)
    public mutating func adoptCurrentDensity(untouched old: Double, now new: Double) {
        guard (densityVersion ?? 1) < Self.currentDensity else { return }
        func lift(_ p: inout ReaderPreferences) { if abs(p.fontScale - old) < 0.001 { p.fontScale = new } }
        lift(&defaults)
        for id in Array(perBook.keys) {
            var p = perBook[id]!
            lift(&p)
            perBook[id] = p == defaults ? nil : p
        }
        densityVersion = Self.currentDensity
    }

    public init(defaults: ReaderPreferences = ReaderPreferences()) {
        self.defaults = defaults
        self.densityVersion = Self.currentDensity
        self.furnitureVersion = Self.currentFurniture
    }

    /// Page numbers, the position label and pages left are his, not a book's look: they always come
    /// from the defaults, so on or off applies to every book (the build 17 review's ruling).
    private static func furniture(of from: ReaderPreferences, onto prefs: inout ReaderPreferences) {
        prefs.showsPageNumbers = from.showsPageNumbers
        prefs.showsPositionLabel = from.showsPositionLabel
        prefs.showsPagesLeft = from.showsPagesLeft
    }

    public func effective(for bookID: String) -> ReaderPreferences {
        guard var own = perBook[bookID] else { return defaults }
        Self.furniture(of: defaults, onto: &own)
        return own
    }

    public func followsDefault(_ bookID: String) -> Bool {
        effective(for: bookID) == defaults
    }

    public mutating func update(_ bookID: String, _ change: (inout ReaderPreferences) -> Void) {
        var prefs = effective(for: bookID)
        change(&prefs)
        Self.furniture(of: prefs, onto: &defaults)
        perBook[bookID] = prefs == defaults ? nil : prefs
    }

    /// Furniture as saved: nil before build 18 (kept per book), `currentFurniture` after (global).
    public private(set) var furnitureVersion: Int?
    public static let currentFurniture = 1

    /// Once, for settings saved by build 17: a toggle he turned on in any book is on for every book,
    /// and a book that differed from his defaults only in furniture follows them again.
    public mutating func adoptGlobalFurniture() {
        guard (furnitureVersion ?? 0) < Self.currentFurniture else { return }
        for prefs in perBook.values {
            defaults.showsPageNumbers = defaults.showsPageNumbers || prefs.showsPageNumbers
            defaults.showsPositionLabel = defaults.showsPositionLabel || prefs.showsPositionLabel
            defaults.showsPagesLeft = defaults.showsPagesLeft || prefs.showsPagesLeft
        }
        for id in Array(perBook.keys) {
            var p = perBook[id]!
            Self.furniture(of: defaults, onto: &p)
            perBook[id] = p == defaults ? nil : p
        }
        furnitureVersion = Self.currentFurniture
    }

    public mutating func useAsDefault(from bookID: String) {
        defaults = effective(for: bookID)
        perBook.removeAll()
    }

    public mutating func updateDefaults(_ change: (inout ReaderPreferences) -> Void) {
        change(&defaults)
    }
}
