import UIKit
import XCTest

/// Every SF Symbol the reader's chrome and Themes & Settings use draws on this OS (calm redesign,
/// 2026-11-03: spacing, margins and justify each get a symbol for their own axis).
final class ChromeSymbolTests: XCTestCase {
    static let symbols = [
        "arrow.up.and.down.text.horizontal", "arrow.left.and.right.text.vertical", "text.justify",
        "book.pages", "circle.lefthalf.filled", "sun.min", "sun.max", "gearshape",
        "square.and.arrow.up", "list.bullet", "textformat.size", "magnifyingglass",
        "bookmark", "bookmark.fill", "xmark", "chevron.backward",
    ]

    func testEverySymbolExists() {
        for name in Self.symbols {
            XCTAssertNotNil(UIImage(systemName: name), "\(name) is missing on iOS \(UIDevice.current.systemVersion)")
        }
    }
}
