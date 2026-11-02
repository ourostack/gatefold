import Foundation

/// A few lines of CSS Gatefold adds to every chapter as the book opens, for markup that reads badly
/// in pages. Today: an illustration whose image the edition left out (Project Gutenberg's
/// text-only EPUBs keep the figure, its caption and its page breaks) takes no page of its own,
/// instead of a blank page and a lonely caption.
public enum BookStyle {
    public static let css = """
    div[class*="fig"]:not(:has(img, svg, image, video)), figure:not(:has(img, svg, image, video)) { display: none !important; }
    """

    /// The chapter with Gatefold's style at the end of its head, so the book's own rules come first.
    public static func inject(into html: String) -> String {
        let tag = "<style id=\"gatefold-book-style\">\(css)</style>"
        if html.contains("gatefold-book-style") { return html }
        if let head = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: head.lowerBound ..< head.lowerBound, with: tag)
        }
        return html
    }

    /// Whether a resource is a chapter the style belongs in.
    public static func applies(toPath path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".xhtml") || p.hasSuffix(".html") || p.hasSuffix(".htm")
    }
}
