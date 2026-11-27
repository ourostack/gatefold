import Foundation
import Testing

/// Every corner Gatefold draws is a squircle (`.continuous`), capsules included, as every Ouro corner is: Ari,
/// 2026-11-20, "ABSOLUTELY NO ROUNDED CORNERS / squircle ONLY … absolutely NO regressions". SwiftUI's `Capsule()`,
/// `RoundedRectangle(cornerRadius:)`, `.rect(cornerRadius:)`, `UnevenRoundedRectangle(…)` and `.cornerRadius(_:)` all
/// default to circular corners, so each must name `.continuous`; the patterns are Ouro UI for Apple's own
/// (`Tests/OuroHXTests/CornerStyleTests.swift`).
///
/// A circle is a squircle closed all the way, so a button, a badge or a panel is never one: a square's squircle has a
/// continuous corner of half its side divided by 1.528 (`Squircle`), short of the circle a continuous corner of half the
/// side draws. Only Ouro's deliberate round things stay round, a slider's thumb, a presence dot, a person's avatar or a
/// spinner, and each says so on its line with a `// round:` note.
@Suite("Corner style")
struct CornerStyleTests {
    /// What draws Gatefold's screens.
    static let folders = ["Gatefold"]

    static let circularCorners: [(name: String, pattern: String)] = [
        ("Capsule without .continuous", #"\bCapsule\((?![^)]*\.continuous)[^)]*\)"#),
        ("style: .circular", #"style:\s*\.circular"#),
        (".cornerRadius(_:)", #"\.cornerRadius\("#),
        ("RoundedRectangle without a style", #"\bRoundedRectangle\(corner(Radius|Size):(?![^\n]*style:)"#),
        ("UnevenRoundedRectangle without a style", #"\bUnevenRoundedRectangle\((?![^\n]*style:)"#),
        (".rect(cornerRadius:) without a style", #"\.rect\((cornerRadius|topLeadingRadius|topTrailingRadius|bottomLeadingRadius|bottomTrailingRadius):(?![^\n]*style:)"#),
        (".capsule shorthand", #"(?<![\w.])\.capsule\b(?!\(style)"#),
        ("a circle with no // round: note", #"(\bCircle\(\)|(?<![\w."])\.circle\b)(?![^\n]*// round:)"#),
    ]

    @Test("no screen draws a circular corner")
    func noCircularCorners() throws {
        // Tests/GatefoldCoreTests/this file -> Tests -> GatefoldCore -> Packages -> the repository.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let patterns = try Self.circularCorners.map { ($0.name, try NSRegularExpression(pattern: $0.pattern)) }
        var found: [String] = []
        var scanned = 0
        for folder in Self.folders {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    let range = NSRange(line.startIndex..., in: line)
                    for (name, regex) in patterns where regex.firstMatch(in: line, range: range) != nil {
                        found.append("\(folder)/\(file.path.components(separatedBy: "/\(folder)/").last ?? file.lastPathComponent):\(index + 1): \(name)")
                    }
                }
            }
        }
        #expect(scanned > 20, "the scan found Gatefold's sources (\(scanned) files under \(root.path))")
        #expect(found.isEmpty, "circular corners:\n\(found.joined(separator: "\n"))")
    }
}
