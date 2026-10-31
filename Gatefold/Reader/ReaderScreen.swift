import GatefoldCore
import SwiftUI

/// The reading screen: the page, laid out for the posture, with chrome that stays out of the way.
struct ReaderScreen: View {
    let model: ReaderModel
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hinge: HingeState = .none
    @State private var showAppearance = LaunchOptions.sheet == "appearance"
    @State private var showContents = LaunchOptions.sheet == "contents"

    var body: some View {
        GeometryReader { proxy in
            let layout = ReaderLayoutResolver.resolve(LayoutInput(
                containerSize: proxy.size,
                division: FoldReader.division(in: proxy),
                hinge: hinge,
                forced: LaunchOptions.forcedPosture
            ))
            ZStack(alignment: .topLeading) {
                model.theme.background

                if let host = model.hostController {
                    ReaderHostView(controller: host)
                        .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                        .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)
                        .accessibilityIdentifier("reader.page")
                }

                if let gutter = layout.gutter {
                    SpineShade(theme: model.theme, depth: layout.spineShadow)
                        .frame(width: gutter.width * 2, height: gutter.height)
                        .offset(x: gutter.midX - gutter.width, y: gutter.minY)
                        .allowsHitTesting(false)
                }

                Ribbon(isOn: model.isBookmarked, color: model.theme.accent)
                    .offset(x: ribbonX(layout), y: layout.pageFrame.minY)
                    .allowsHitTesting(false)

                if let deck = layout.deck {
                    TabletopDeck(model: model, showAppearance: $showAppearance, showContents: $showContents)
                        .frame(width: deck.width, height: deck.height)
                        .offset(x: deck.minX, y: deck.minY)
                }

                ReaderChrome(
                    model: model,
                    layout: layout,
                    insets: proxy.safeAreaInsets,
                    onClose: onClose,
                    showAppearance: $showAppearance,
                    showContents: $showContents
                )
                .frame(width: proxy.size.width, height: layout.deck == nil ? proxy.size.height : layout.pageFrame.height)

                if let suggestion = model.suggestion {
                    JumpBanner(suggestion: suggestion, theme: model.theme) {
                        Task { await model.acceptSuggestion() }
                    } onDismiss: {
                        model.dismissSuggestion()
                    }
                    .frame(width: min(proxy.size.width - 32, 460))
                    .position(x: layout.gutter.map { _ in proxy.size.width * 0.75 } ?? proxy.size.width / 2, y: proxy.safeAreaInsets.top + 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Text(model.anchorCheck)
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .accessibilityIdentifier("reader.anchorCheck")
                    .accessibilityLabel(model.anchorCheck)
                    .allowsHitTesting(false)
            }
            .onChange(of: layout, initial: true) { old, new in
                let reason: ReflowReason = old.posture != new.posture ? .posture : .rotation
                withAnimation(Motion.reflow) { model.updateLayout(new, reason: reason) }
            }
        }
        .ignoresSafeArea()
        .observingHinge($hinge)
        .preferredColorScheme(model.theme.colorScheme)
        .statusBarHidden(!model.chromeVisible)
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
        .sheet(isPresented: $showAppearance) {
            AppearanceSheet(model: model)
        }
        .sheet(isPresented: $showContents) {
            ContentsSheet(model: model)
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            let dark = scheme == .dark
            if model.systemIsDark != dark {
                model.systemIsDark = dark
                model.applyPreferences(reflow: false)
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, reduce in
            model.reduceMotion = reduce
        }
        .task { await model.load() }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func ribbonX(_ layout: ReaderLayout) -> CGFloat {
        if let gutter = layout.gutter {
            return gutter.maxX + 6
        }
        return layout.pageFrame.maxX - 54
    }
}

/// The shadow where facing pages meet, deeper as the device bends.
private struct SpineShade: View {
    let theme: ReaderTheme
    let depth: Double

    var body: some View {
        let strength = (theme.palette.isDark ? 0.45 : 0.10) + depth * 0.18
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(strength * 0.35), location: 0.38),
                .init(color: .black.opacity(strength), location: 0.5),
                .init(color: .black.opacity(strength * 0.35), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .blendMode(theme.palette.isDark ? .normal : .multiply)
    }
}

/// A silk ribbon that drops onto the page when it's bookmarked.
struct Ribbon: View {
    let isOn: Bool
    let color: Color

    var body: some View {
        RibbonShape()
            .fill(color.gradient)
            .frame(width: 20, height: 46)
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .offset(y: isOn ? 0 : -60)
            .opacity(isOn ? 1 : 0)
            .animation(.spring(duration: 0.4, bounce: 0.4), value: isOn)
            .accessibilityHidden(true)
    }
}

struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.45))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
