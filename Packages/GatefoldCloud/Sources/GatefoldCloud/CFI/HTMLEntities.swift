import Foundation

/// XMLParser rejects HTML named entities that real-world EPUBs still use. Rewrite them as
/// numeric references before parsing; unknown names become U+FFFD so parsing never fails.
enum HTMLEntities {
    static let table: [String: UInt32] = [
        "nbsp": 0xA0, "iexcl": 0xA1, "cent": 0xA2, "pound": 0xA3, "yen": 0xA5, "sect": 0xA7,
        "copy": 0xA9, "laquo": 0xAB, "shy": 0xAD, "reg": 0xAE, "deg": 0xB0, "plusmn": 0xB1,
        "middot": 0xB7, "raquo": 0xBB, "frac14": 0xBC, "frac12": 0xBD, "frac34": 0xBE, "iquest": 0xBF,
        "Agrave": 0xC0, "Aacute": 0xC1, "Acirc": 0xC2, "Auml": 0xC4, "Ccedil": 0xC7, "Egrave": 0xC8,
        "Eacute": 0xC9, "Ecirc": 0xCA, "Ouml": 0xD6, "Uuml": 0xDC, "szlig": 0xDF, "agrave": 0xE0,
        "aacute": 0xE1, "acirc": 0xE2, "atilde": 0xE3, "auml": 0xE4, "aring": 0xE5, "aelig": 0xE6,
        "ccedil": 0xE7, "egrave": 0xE8, "eacute": 0xE9, "ecirc": 0xEA, "euml": 0xEB, "igrave": 0xEC,
        "iacute": 0xED, "icirc": 0xEE, "iuml": 0xEF, "ntilde": 0xF1, "ograve": 0xF2, "oacute": 0xF3,
        "ocirc": 0xF4, "otilde": 0xF5, "ouml": 0xF6, "divide": 0xF7, "oslash": 0xF8, "ugrave": 0xF9,
        "uacute": 0xFA, "ucirc": 0xFB, "uuml": 0xFC, "yuml": 0xFF, "times": 0xD7, "OElig": 0x152,
        "oelig": 0x153, "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C,
        "zwj": 0x200D, "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019,
        "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E, "dagger": 0x2020,
        "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026, "prime": 0x2032, "Prime": 0x2033,
        "lsaquo": 0x2039, "rsaquo": 0x203A, "euro": 0x20AC, "trade": 0x2122,
    ]
    static let xmlBuiltins: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    static func numericize(_ source: String) -> String {
        guard source.contains("&") else { return source }
        var out = ""
        out.reserveCapacity(source.utf8.count)
        var rest = Substring(source)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(32).firstIndex(of: ";") {
                let name = String(after[..<semi])
                if name.first.map({ $0.isLetter }) == true, name.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    if xmlBuiltins.contains(name) { out += "&\(name);" }
                    else { out += "&#\(table[name] ?? 0xFFFD);" }
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }
}
