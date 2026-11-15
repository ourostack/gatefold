import GatefoldCore
import OuroHX
import SwiftUI

extension OuroTheme {
    /// Ouro UI's kit in Gatefold's colours: Pearl, with the ribbon as its primary, so an `OuroButton` or
    /// `OuroBanner` action is drawn in the ribbon (#2F5D8A by day, #7FA6D6 by night), not Pearl's #0066cc.
    static let gatefold = OuroTheme(
        name: .pearl,
        light: OuroColors.ribboned(OuroTokens.pearl.light, ribbon: Brand.light),
        dark: OuroColors.ribboned(OuroTokens.pearl.dark, ribbon: Brand.dark),
        radius: OuroTokens.pearl.radius,
        extras: OuroTokens.pearl.extras
    )
}

extension OuroColors {
    /// A theme's colours with the ribbon wherever Ouro UI draws its primary: fills, focus rings and their labels.
    static func ribboned(_ base: OuroColors, ribbon brand: Brand) -> OuroColors {
        let ribbon = Color(hex: brand.ribbon)
        let onRibbon = Color(hex: brand.onRibbon)
        return OuroColors(
            background: base.background,
            foreground: base.foreground,
            card: base.card,
            cardForeground: base.cardForeground,
            popover: base.popover,
            popoverForeground: base.popoverForeground,
            primary: ribbon,
            primaryForeground: onRibbon,
            secondary: base.secondary,
            secondaryForeground: base.secondaryForeground,
            muted: base.muted,
            mutedForeground: base.mutedForeground,
            accent: base.accent,
            accentForeground: base.accentForeground,
            destructive: base.destructive,
            destructiveForeground: base.destructiveForeground,
            border: base.border,
            input: base.input,
            ring: ribbon,
            success: base.success,
            successForeground: base.successForeground,
            warning: base.warning,
            warningForeground: base.warningForeground,
            chart1: base.chart1,
            chart2: base.chart2,
            chart3: base.chart3,
            chart4: base.chart4,
            chart5: base.chart5,
            avatar1: base.avatar1,
            avatar2: base.avatar2,
            avatar3: base.avatar3,
            avatar4: base.avatar4,
            avatar5: base.avatar5,
            avatar6: base.avatar6,
            avatar7: base.avatar7,
            avatar8: base.avatar8,
            sidebar: base.sidebar,
            sidebarForeground: base.sidebarForeground,
            sidebarPrimary: ribbon,
            sidebarPrimaryForeground: onRibbon,
            sidebarAccent: base.sidebarAccent,
            sidebarAccentForeground: base.sidebarAccentForeground,
            sidebarBorder: base.sidebarBorder,
            sidebarRing: ribbon
        )
    }
}
