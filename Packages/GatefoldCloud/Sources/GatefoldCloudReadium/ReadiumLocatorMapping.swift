#if canImport(ReadiumShared)
import Foundation
import GatefoldCloud
import ReadiumShared

/// Readium's `Locator` ⇄ `BookLocation`. Pair with `PositionMapper` to get Cloud positions:
///
///     let position = await mapper.position(for: BookLocation(locator), at: .now)
///     let locator = await mapper.location(for: remote).flatMap { Locator($0) }
public extension BookLocation {
    init(_ locator: Locator) {
        let cfi: String? = if case let .string(value)? = locator.locations.otherLocations["cfi"] { value } else { nil }
        self.init(href: locator.href.string, progression: locator.locations.progression,
                  totalProgression: locator.locations.totalProgression, cfi: cfi, textAfter: locator.text.after)
    }
}

public extension Locator {
    /// Nil when `href` is not a valid relative path.
    init?(_ location: BookLocation, mediaType: MediaType = .xhtml, title: String? = nil) {
        guard let href = AnyURL(path: location.href) else { return nil }
        var other: [String: JSONValue] = [:]
        if let cfi = location.cfi { other["cfi"] = .string(cfi) }
        self.init(href: href, mediaType: mediaType, title: title,
                  locations: .init(progression: location.progression, totalProgression: location.totalProgression, otherLocations: other),
                  text: .init(after: location.textAfter))
    }
}
#endif
