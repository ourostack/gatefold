import GatefoldCore
import OuroHX
import SwiftUI

extension OuroTheme {
    /// Ouro UI's kit in Gatefold's colours: Pearl, with the ribbon as its primary, so an `OuroButton` or
    /// `OuroBanner` action is drawn in the ribbon (#2F5D8A by day, #7FA6D6 by night), not Pearl's #0066cc. The
    /// focus rings and the sidebar's primary follow it; everything else is Pearl's.
    static let gatefold = OuroTokens.pearl.withPrimary(
        light: Color(hex: Brand.light.ribbon),
        dark: Color(hex: Brand.dark.ribbon),
        lightLabel: Color(hex: Brand.light.onRibbon),
        darkLabel: Color(hex: Brand.dark.onRibbon)
    )
}
