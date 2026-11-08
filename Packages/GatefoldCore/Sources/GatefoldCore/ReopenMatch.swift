/// Whether a reopen showed the spread he left, judged from the words at the top of each.
///
/// His place is the page's first whole word: a page that opens on the end of a word hyphenated across
/// the turn saves the word after it, and the reopen starts there, the fragment left on the page before.
/// That reopen is his page only when the place the app saved proves the dropped token was a fragment;
/// a page that opened on a whole word and reopens one word later has skipped his place.
public enum ReopenMatch: String, Sendable {
    /// The reopened spread starts with the words the left one started with.
    case exact
    /// It starts at the left spread's second token, and the saved place started there too.
    case fromSavedWholeWord
    /// Neither: a different spread.
    case different

    public static let headLength = 30

    /// - Parameters:
    ///   - left: the words on the spread he left. - reopened: the words on the spread the reopen shows.
    ///   - saved: the words of the place the app saved for the spread he left, nil when unknown.
    public static func compare(left: String, reopened: String, saved: String?) -> ReopenMatch {
        let l = normalized(left), r = normalized(reopened)
        guard !l.isEmpty, !r.isEmpty else { return .different }
        if head(r) == head(l) { return .exact }
        let words = l.split(separator: " ", maxSplits: 1)
        guard words.count == 2, let saved = saved.map(normalized), !saved.isEmpty else { return .different }
        let whole = String(words[1])
        // The proof: the app's own place starts at the second token, which it does only for a word's tail.
        let n = min(headLength, saved.count, whole.count)
        guard n > 0, saved.prefix(n) == whole.prefix(n) else { return .different }
        return head(r) == head(whole) ? .fromSavedWholeWord : .different
    }

    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func head(_ s: String) -> String { String(s.prefix(headLength)) }
}
