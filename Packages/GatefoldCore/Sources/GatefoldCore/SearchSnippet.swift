import Foundation

/// The words a search result shows before its match. Readium gives a long run of text before it, and on the folded
/// Duo three lines of that ran out before the match came (review panel 2026-11-22): only the last few words are kept,
/// from a word's start, after an ellipsis, so the match is in the first line or two, as Apple Books shows it.
public enum SearchSnippet {
    /// The most characters kept before the match, the ellipsis aside: about a line on the folded Duo.
    public static let leadLimit = 40

    public static func lead(_ before: String) -> String {
        let text = before.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard text.count > leadLimit else { return text }
        let tail = text.suffix(leadLimit)
        // From the first whole word: past the first space, unless the cut fell right at a word's start.
        let cutMidWord = text.dropLast(leadLimit).last.map { !$0.isWhitespace } ?? false
        let words = cutMidWord ? tail.drop(while: { !$0.isWhitespace }) : tail[...]
        let trimmed = words.drop(while: \.isWhitespace)
        return trimmed.isEmpty ? String(tail) : "…" + trimmed
    }
}
