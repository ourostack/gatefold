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
