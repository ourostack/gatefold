@testable import Gatefold
import GatefoldCore
import OuroHX
import SwiftUI
import Testing
import UIKit

/// Ouro UI's kit draws in the ribbon, not Pearl's #0066cc.
@MainActor
struct OuroThemeTests {
    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    @Test("the kit's primary, ring and their labels are the ribbon's, by day and by night")
    func primaryIsTheRibbon() {
        let theme = OuroTheme.gatefold
        #expect(hex(theme.light.primary, .light) == Brand.light.ribbon)
        #expect(hex(theme.light.ring, .light) == Brand.light.ribbon)
        #expect(hex(theme.light.primaryForeground, .light) == Brand.light.onRibbon)
        #expect(hex(theme.dark.primary, .dark) == Brand.dark.ribbon)
        #expect(hex(theme.dark.primaryForeground, .dark) == Brand.dark.onRibbon)
        #expect(hex(theme.light.primary, .light) != 0x0066CC)
    }

    @Test("everything else is Pearl's")
    func restIsPearl() {
        #expect(hex(OuroTheme.gatefold.light.background, .light) == hex(OuroTokens.pearl.light.background, .light))
        #expect(hex(OuroTheme.gatefold.dark.destructive, .dark) == hex(OuroTokens.pearl.dark.destructive, .dark))
        #expect(OuroTheme.gatefold.radius == OuroTokens.pearl.radius)
    }
}
