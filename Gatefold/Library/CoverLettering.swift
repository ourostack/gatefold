import SwiftUI
import UIKit

/// The lettering on a made cover (a book with no cover picture gets one in the shelf's cloth): its title and author.
/// The lines are broken here, not by SwiftUI, and each is set as one line in the font it was measured in. So a line
/// breaks only where the language allows (between words, after a hyphen, between Chinese or Japanese characters),
/// never inside a word and never with a hyphen of its own. On the phone's 100 pt grid SwiftUI broke WOLLSTONECRA / FT
/// and hyphenated Franken- / stein.
///
/// A part's lines shrink together, to no less than `floor`, until each fits the cover's width and all of them its
/// height. At the floor, a word still too wide is cut with an ellipsis, and so is the last line that fits the height.
enum CoverLettering {
    enum Kind { case title, author }

    /// How far a part's lines may shrink.
    static let floor: CGFloat = 0.6
    /// The cover's margin around the lettering, and the room between the rules, the title and the author.
    static let padding: CGFloat = 12
    static let spacing: CGFloat = 10
    /// The thin rules above and below.
    static let rule: CGFloat = 1
    /// Most lines an author's name takes.
    static let authorLines = 3
    /// Room left unused at a line's end, against rounding between this measurement and SwiftUI's.
    static let slack: CGFloat = 2

    /// A part's lines and the scale they are set at.
    struct Setting: Equatable {
        var lines: [String]
        var scale: CGFloat
    }

    /// The width the lettering has on a cover this wide.
    static func room(onCoverWidth width: CGFloat) -> CGFloat { max(width - 2 * padding, 1) }

    /// The title's and the author's settings on a cover of this size.
    static func layout(title: String, author: String, cover: CGSize, typeSize: DynamicTypeSize, bold: Bool) -> (title: Setting, author: Setting?) {
        let width = room(onCoverWidth: cover.width)
        let byline = author.isEmpty ? nil : set(author.uppercased(), font: font(.author, typeSize, bold: bold), tracking: tracking(.author),
                                                 width: width, height: font(.author, typeSize, bold: bold).lineHeight * CGFloat(authorLines))
        let authorFont = font(.author, typeSize, bold: bold)
        let bylineHeight = byline.map { CGFloat($0.lines.count) * authorFont.lineHeight * $0.scale + spacing } ?? 0
        let tall = cover.height - 2 * padding - 2 * rule - 2 * spacing - bylineHeight
        let title = set(title, font: font(.title, typeSize, bold: bold), tracking: tracking(.title), width: width, height: max(tall, 1))
        return (title, byline)
    }

    /// Lines of `text`, broken only where the language allows, each no wider than `width`, together no taller than
    /// `height`, at the largest scale from 1 down to `floor` where that works; at the floor, cut to fit.
    static func set(_ text: String, font: UIFont, tracking: CGFloat, width: CGFloat, height: CGFloat) -> Setting {
        let width = max(width - slack, 1)
        let parts = pieces(text)
        var scale: CGFloat = 1
        while true {
            let small = font.withSize(font.pointSize * scale), spread = tracking * scale
            let most = max(1, Int((height / small.lineHeight).rounded(.down)))
            let lines = pack(parts, font: small, tracking: spread, width: width)
            if lines.count <= most, lines.allSatisfy({ measure($0, font: small, tracking: spread) <= width }) {
                return Setting(lines: lines, scale: scale)
            }
            if scale <= floor {
                let whole = parts.map { measure(trimmed($0), font: small, tracking: spread) <= width ? $0 : cut($0, font: small, tracking: spread, width: width) + " " }
                var lines = pack(whole, font: small, tracking: spread, width: width)
                if lines.count > most {
                    lines = Array(lines.prefix(most))
                    lines[most - 1] = cut(lines[most - 1], font: small, tracking: spread, width: width, always: true)
                }
                return Setting(lines: lines, scale: floor)
            }
            scale = max(floor, scale - 0.02)
        }
    }

    /// The text cut where a line may break, by the system's line-breaking rules: each piece keeps the spaces after it.
    static func pieces(_ text: String) -> [String] {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: string.length),
                                                kCFStringTokenizerUnitLineBreak, nil)
        var starts: [Int] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            starts.append(CFStringTokenizerGetCurrentTokenRange(tokenizer).location)
        }
        let bounds = ([0] + starts.filter { $0 > 0 }) + [string.length]
        return zip(bounds, bounds.dropFirst()).compactMap { start, end in
            end > start ? string.substring(with: NSRange(location: start, length: end - start)) : nil
        }
    }

    /// The pieces gathered greedily into lines no wider than `width` (a piece wider than that has a line of its own).
    static func pack(_ parts: [String], font: UIFont, tracking: CGFloat, width: CGFloat) -> [String] {
        var lines: [String] = [], line = ""
        for part in parts {
            if line.isEmpty || measure(trimmed(line + part), font: font, tracking: tracking) <= width {
                line += part
            } else {
                lines.append(trimmed(line))
                line = part
            }
        }
        if !trimmed(line).isEmpty { lines.append(trimmed(line)) }
        return lines
    }

    /// The start of `text` that fits `width` with an ellipsis after it, or the text itself when it fits and an
    /// ellipsis isn't asked for.
    static func cut(_ text: String, font: UIFont, tracking: CGFloat, width: CGFloat, always: Bool = false) -> String {
        var start = trimmed(text)
        if !always, measure(start, font: font, tracking: tracking) <= width { return start }
        while !start.isEmpty, measure(trimmed(start) + "…", font: font, tracking: tracking) > width { start.removeLast() }
        return trimmed(start) + "…"
    }

    /// How wide a line sets in this font with this tracking, as SwiftUI's `tracking` adds it.
    static func measure(_ line: String, font: UIFont, tracking: CGFloat) -> CGFloat {
        (line as NSString).size(withAttributes: [.font: font, .tracking: tracking]).width
    }

    static func trimmed(_ text: String) -> String {
        String(text.reversed().drop(while: \.isWhitespace).reversed())
    }

    static func tracking(_ kind: Kind) -> CGFloat { kind == .author ? 1.2 : 0 }

    /// The title in the serif headline (the one serif moment, like a colophon) at the reader's text size; the author in
    /// small capitals at a fixed 9 pt. Both a step heavier with Bold Text, as SwiftUI's own fonts are.
    static func font(_ kind: Kind, _ size: DynamicTypeSize, bold: Bool) -> UIFont {
        switch kind {
        case .title:
            let traits = UITraitCollection(traitsFrom: [UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)),
                                                        UITraitCollection(legibilityWeight: bold ? .bold : .regular)])
            let headline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
            return headline.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 0) } ?? headline
        case .author:
            return .systemFont(ofSize: 9, weight: bold ? .semibold : .medium)
        }
    }
}

/// A part of a made cover's lettering, one Text per line, each in exactly the font its line was measured in.
struct CoverLines: View {
    let setting: CoverLettering.Setting
    let font: UIFont
    let tracking: CGFloat

    var body: some View {
        let size = font.withSize(font.pointSize * setting.scale)
        VStack(spacing: 0) {
            ForEach(Array(setting.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Font(size as CTFont))
                    .tracking(tracking * setting.scale)
                    .lineLimit(1)
                    // Only against a hair's difference between measuring and drawing: shrink, never wrap or cut.
                    .minimumScaleFactor(0.9)
            }
        }
    }
}
