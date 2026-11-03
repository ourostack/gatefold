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

    public init() {}

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
    public static func initialFontScale(forContentSizeRank rank: Int) -> Double {
        let scales: [Double] = [0.8, 0.9, 0.95, 1.0, 1.1, 1.2, 1.3, 1.5, 1.7, 1.9, 2.1, 2.3]
        return scales[min(max(rank, 0), scales.count - 1)]
    }
}

/// Settings for every book, with optional per-book overrides. "Use as default" turns one book's
/// look into everyone's, which Books can't do and PocketBook readers ask for.
public struct PreferencesStore: Codable, Equatable, Sendable {
    public private(set) var defaults: ReaderPreferences
    private var perBook: [String: ReaderPreferences] = [:]

    public init(defaults: ReaderPreferences = ReaderPreferences()) {
        self.defaults = defaults
    }

    public func effective(for bookID: String) -> ReaderPreferences {
        perBook[bookID] ?? defaults
    }

    public func followsDefault(_ bookID: String) -> Bool {
        effective(for: bookID) == defaults
    }

    public mutating func update(_ bookID: String, _ change: (inout ReaderPreferences) -> Void) {
        var prefs = effective(for: bookID)
        change(&prefs)
        perBook[bookID] = prefs == defaults ? nil : prefs
    }

    public mutating func useAsDefault(from bookID: String) {
        defaults = effective(for: bookID)
        perBook.removeAll()
    }

    public mutating func updateDefaults(_ change: (inout ReaderPreferences) -> Void) {
        change(&defaults)
    }
}
