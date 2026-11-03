import Foundation

/// A friendly, forgiving look at a typed email before it goes anywhere: one @, a name before it,
/// a domain with a dot after it, no spaces. Not RFC 5322; just enough to catch `ari@mendelow@me`.
public enum EmailCheck {
    public enum Problem: Equatable, Sendable {
        case space
        case missingAt
        case tooManyAts
        case missingName
        case missingDomain
        /// The part after the @ has no dot, or a dot with nothing on one side (`me`, `mendelow.`, `.me`).
        case missingDot
    }

    /// Nil when the address looks like an email. Leading and trailing whitespace is ignored (sign-in trims it).
    public static func problem(_ typed: String) -> Problem? {
        let email = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.contains(where: \.isWhitespace) { return .space }
        let ats = email.filter { $0 == "@" }.count
        if ats == 0 { return .missingAt }
        if ats > 1 { return .tooManyAts }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        if parts[0].isEmpty { return .missingName }
        let domain = parts[1]
        if domain.isEmpty { return .missingDomain }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count < 2 || labels.contains(where: \.isEmpty) { return .missingDot }
        return nil
    }

    public static func isPlausible(_ typed: String) -> Bool { problem(typed) == nil }
}
