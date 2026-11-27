import SwiftUI
import UIKit

/// The lettering on a made cover (a book with no cover picture gets one in the shelf's cloth): its title and author.
/// Stub for the tests: each part is one run of text that SwiftUI wraps however it likes, as today, which on the
/// phone's 100 pt grid breaks WOLLSTONECRA / FT and hyphenates Franken- / stein.
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

    /// Stub: each part as it is, at full size.
    static func layout(title: String, author: String, cover: CGSize, typeSize: DynamicTypeSize, bold: Bool) -> (title: Setting, author: Setting?) {
        (Setting(lines: [title], scale: 1), author.isEmpty ? nil : Setting(lines: [author.uppercased()], scale: 1))
    }

    /// Stub: the text as it is.
    static func pieces(_ text: String) -> [String] { [text] }

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

/// A part of a made cover's lettering. Stub: one Text that wraps as SwiftUI likes.
struct CoverLines: View {
    let setting: CoverLettering.Setting
    let font: UIFont
    let tracking: CGFloat

    var body: some View {
        Text(setting.lines.joined(separator: " "))
            .font(Font(font.withSize(font.pointSize * setting.scale) as CTFont))
            .tracking(tracking * setting.scale)
            .multilineTextAlignment(.center)
    }
}
