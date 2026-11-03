import Foundation

/// Words at a place in a chapter, for a slip that quotes where the other device stopped.
public enum PassageText {
    /// The body text of an XHTML chapter: tags dropped, entities read, whitespace collapsed.
    public static func plainText(ofHTML html: String) -> String {
        var body = html
        if let open = html.range(of: "<body", options: .caseInsensitive) { body = String(html[open.lowerBound...]) }
        body = body.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1>"#, with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&hellip;": "…"] {
            body = body.replacingOccurrences(of: entity, with: char)
        }
        body = body.replacingOccurrences(of: #"&#(\d+);"#, with: " ", options: .regularExpression)
        return body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The sentence that starts at or just after `fraction` of the way through the chapter's text.
    public static func sentence(inHTML html: String, at fraction: Double) -> String? {
        let text = plainText(ofHTML: html)
        guard !text.isEmpty else { return nil }
        let chars = Array(text)
        var i = min(chars.count - 1, max(0, Int(Double(chars.count) * min(1, max(0, fraction)))))
        // Forward to the next sentence start, unless we're already at one.
        let enders: Set<Character> = [".", "!", "?", "”"]
        if i > 0 {
            var j = i
            while j < chars.count - 1, !(enders.contains(chars[j]) && chars[j + 1] == " ") { j += 1 }
            i = j < chars.count - 1 ? j + 2 : i
        }
        let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
        guard rest.count >= 12 else { return nil }
        return String(rest.prefix(120))
    }
}

/// A quoted passage cut at a character count can stop inside a word ("to compli"); a mark on the page
/// ends where the word does, so the cut moves forward into the text that follows.
public enum WordEdge {
    /// `highlight` extended to the end of its last word, taking the letters from `after`; returns the new
    /// highlight and what is left of `after`.
    public static func complete(highlight: String, after: String?) -> (highlight: String, after: String?) {
        guard let after, let last = highlight.last, last.isLetter || last.isNumber || last == "'" || last == "’" else {
            return (highlight, after)
        }
        let tail = after.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        guard !tail.isEmpty else { return (highlight, after) }
        return (highlight + tail, String(after.dropFirst(tail.count)))
    }
}

/// A passage shown in quote marks on a slip or in a list. A passage that already opens with a quote mark
/// (dialogue, mostly) is shown as it is: wrapping it again would read ““Like this.”
public enum PassageQuote {
    /// Marks that open a quotation in the languages books come in: straight and curly quotes, low-9
    /// quotes, and guillemets either way round (French «…», German and Danish »…«).
    static let openers: Set<Character> = ["\"", "'", "“", "‘", "”", "’", "„", "‚", "«", "»", "‹", "›", "「", "『"]

    public static func startsQuoted(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
        return openers.contains(first)
    }

    /// `text` in curly quotes, with `…` before the closing mark when `cut` (the passage stops mid-sentence);
    /// or as it is (with `…` after it) when it already opens with a quote mark.
    public static func quoted(_ text: String, cut: Bool = false) -> String {
        let body = text.trimmingCharacters(in: .whitespaces)
        let tail = cut && !body.hasSuffix("…") ? "…" : ""
        return startsQuoted(body) ? body + tail : "“" + body + tail + "”"
    }
}
