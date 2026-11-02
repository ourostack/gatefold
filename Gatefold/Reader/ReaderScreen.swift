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
    /// A posture forced for screenshots and UI tests; nil follows the device.
    @State private var forced: Posture? = LaunchOptions.forcedPosture
    /// The unfold leaf: its angle about the spine, and how much of it shows.
    @State private var leafAngle = 0.0
    @State private var leafOpacity = 0.0
    @State private var leafFolding = false
    @State private var spineBoost = 0.0
    /// On the cover screen the status column sits on the page's trailing edge; it stays hidden there.
    @State private var coverScreen = false
    @State private var slipHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let input = LayoutInput(
                containerSize: proxy.size,
                division: FoldReader.division(in: proxy),
                hinge: hinge,
                forced: forced
            )
            let layout = Self.placed(input, fontScale: model.preferences.fontScale, proxy: proxy, bare: !model.chromeVisible && !coverScreen)
            let clearance = ChromeClearance.resolve(container: proxy.size, occlusions: FoldReader.occlusions(in: proxy))
            let safeTop = ReaderChrome.safeTop(proxy.safeAreaInsets)
            // The page steps back while the controls or a slip are up, so nothing sits on its text.
            let lifted = (model.chromeVisible && layout.deck == nil) || (model.slip != nil && !model.slipFolded)
            ZStack(alignment: .topLeading) {
                model.theme.background

                page(layout, clearance: clearance)
                    .scaleEffect(lifted && !reduceMotion ? 0.96 : 1, anchor: .center)
                    .animation(.spring(duration: 0.25), value: lifted)

                scrims(proxy: proxy, layout: layout, safeTop: safeTop)

                if let deck = layout.deck {
                    TabletopDeck(model: model, showAppearance: $showAppearance, showContents: $showContents)
                        .frame(width: deck.width, height: deck.height)
                        .offset(x: deck.minX, y: deck.minY)
                }

                ReaderChrome(
                    model: model,
                    layout: layout,
                    insets: proxy.safeAreaInsets,
                    clearance: clearance,
                    onClose: onClose,
                    showAppearance: $showAppearance,
                    showContents: $showContents
                )
                .frame(width: proxy.size.width, height: layout.deck == nil ? proxy.size.height : layout.pageFrame.height)

                if let tab = model.aheadTab, model.slipFolded, model.slip != nil {
                    // Hangs from the page's top edge in its margin, beside the binding: never on a line.
                    AheadTab(label: tab, theme: model.theme) { model.unfoldSlip() }
                        .offset(x: layout.pageFrame.minX + 16, y: layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance) - 22)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }

                if let slip = model.slip, let kind = model.slipKind, !model.slipFolded {
                    let width = min(proxy.size.width - 32 - clearance.leading - clearance.trailing, 460)
                    SyncSlipView(slip: slip, kind: kind, theme: model.theme) {
                        Task { await model.acceptSuggestion() }
                    } onStay: {
                        model.dismissSuggestion()
                    }
                    .frame(width: width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slipHeight = $0 }
                    // "Ahead" sits in the top band, under the title when the controls are up. "Landed" sits
                    // at the foot, so the passage it underlines (the top line of the page) stays in view.
                    .offset(
                        x: layout.gutter.map { g in g.maxX + (proxy.size.width - g.maxX - width) / 2 } ?? (proxy.size.width - width) / 2,
                        y: kind == .landed
                            ? proxy.size.height - slipBottomBand(proxy) - slipHeight
                            : safeTop + 8 + (model.chromeVisible ? ReaderChrome.topBarHeight : 0)
                    )
                    .animation(Motion.chrome, value: model.chromeVisible)
                    .transition(reduceMotion ? .opacity : .move(edge: kind == .landed ? .bottom : .top).combined(with: .opacity))
                    .zIndex(2)
                }

                if !model.pageReady {
                    OpeningPlaceholder(model: model)
                        .transition(.opacity)
                        .zIndex(3)
                }

                if let leaf = model.endLeaf {
                    EndLeafView(model: model, leaf: leaf, onLibrary: onClose)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                        .zIndex(4)
                }

                probes(layout)
            }
            .sensoryFeedback(.success, trigger: model.slipCount) { _, _ in model.slipKind == .landed }
            .onChange(of: clearance.bookmarkLeading, initial: true) { _, taken in coverScreen = taken }
            .onChange(of: FoldReader.occlusions(in: proxy), initial: true) { _, rects in
                readerLog.notice("occlusions \(rects.map { "\($0)" }.joined(separator: " "), privacy: .public) safe \(proxy.safeAreaInsets.top, privacy: .public),\(proxy.safeAreaInsets.leading, privacy: .public),\(proxy.safeAreaInsets.bottom, privacy: .public),\(proxy.safeAreaInsets.trailing, privacy: .public) size \(proxy.size.width, privacy: .public)x\(proxy.size.height, privacy: .public)")
            }
            .onChange(of: input, initial: true) { _, new in
                readerLog.notice("layout input \(new.containerSize.width, privacy: .public)x\(new.containerSize.height, privacy: .public) fold \(new.division.map { "\($0.frame) active \($0.isActive)" } ?? "none", privacy: .public) hinge \(String(describing: new.hinge), privacy: .public)")
            }
            .onChange(of: layout, initial: true) { old, new in
                let reason: ReflowReason = old.posture != new.posture ? .posture : .rotation
                withAnimation(Motion.reflow) { model.updateLayout(new, reason: reason) }
                if old.posture != .spread, new.posture == .spread { unfold() }
                if old.posture == .spread, new.posture != .spread { fold() }
            }
        }
        .ignoresSafeArea()
        .observingHinge($hinge)
        .preferredColorScheme(model.theme.colorScheme)
        .statusBarHidden(!model.chromeVisible || coverScreen)
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
        .task { await flipForFilming() }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The page, the spine, the unfold leaf and the ribbon: everything that steps back together.
    private func page(_ layout: ReaderLayout, clearance: ChromeClearance) -> some View {
        ZStack(alignment: .topLeading) {
            if let host = model.hostController {
                ReaderHostView(controller: host)
                    .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                    .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)
                    .accessibilityIdentifier("reader.page")
            }

            if let gutter = layout.gutter {
                // The right page swings open from the spine.
                if leafOpacity > 0 {
                    UnfoldLeaf(theme: model.theme, angle: leafAngle, opacity: leafOpacity)
                        .frame(width: max(0, layout.pageFrame.maxX - gutter.midX), height: layout.pageFrame.height)
                        .offset(x: gutter.midX, y: layout.pageFrame.minY)
                }
                SpineShade(theme: model.theme, depth: min(1, layout.spineShadow + spineBoost))
                    .frame(width: gutter.width * 2, height: gutter.height)
                    .offset(x: gutter.midX - gutter.width, y: gutter.minY)
                    .allowsHitTesting(false)
            } else if leafFolding, leafOpacity > 0 {
                UnfoldLeaf(theme: model.theme, angle: leafAngle, opacity: leafOpacity)
                    .frame(width: layout.pageFrame.width / 2, height: layout.pageFrame.height)
                    .offset(x: layout.pageFrame.midX, y: layout.pageFrame.minY)
            }

            Ribbon(isOn: model.isBookmarked, color: model.theme.accent) {
                Task { await model.toggleBookmark() }
            }
            .offset(x: ribbonX(layout, clearance: clearance), y: layout.pageFrame.minY)
        }
    }

    /// Space below a slip at the foot of the page: the home indicator, and the controls when up.
    private func slipBottomBand(_ proxy: GeometryProxy) -> CGFloat {
        max(proxy.safeAreaInsets.bottom, 12) + 8 + (model.chromeVisible ? ReaderChrome.bottomBarHeight : 0)
    }

    /// The theme's own paper under the bars, fading to clear over 24 pt, so glass never sits on text.
    @ViewBuilder
    private func scrims(proxy: GeometryProxy, layout: ReaderLayout, safeTop: CGFloat) -> some View {
        let fade: CGFloat = 24
        let paper = model.theme.background
        let aheadSlip = model.slip != nil && model.slipKind == .ahead && !model.slipFolded
        let landedSlip = model.slip != nil && model.slipKind == .landed
        let top = safeTop + (model.chromeVisible ? ReaderChrome.topBarHeight : 0) + (aheadSlip ? 8 + slipHeight + 16 : 0)
        if model.chromeVisible || aheadSlip {
            LinearGradient(stops: [.init(color: paper, location: 0), .init(color: paper, location: top / (top + fade)), .init(color: paper.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: top + fade)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
        let backAlone = model.showJumpBack && !model.chromeVisible && layout.deck == nil && model.backLocator != nil
        if (model.chromeVisible && layout.deck == nil) || landedSlip || backAlone {
            let bottom = max(
                model.chromeVisible && layout.deck == nil ? max(proxy.safeAreaInsets.bottom, 12) + ReaderChrome.bottomBarHeight + (model.backLocator != nil ? 52 : 0) : 0,
                // After a Jump the Back pill gets its own paper footer: it never sits on a line.
                backAlone ? max(proxy.safeAreaInsets.bottom, 12) + 52 : 0,
                landedSlip ? slipBottomBand(proxy) + slipHeight + 16 : 0
            )
            LinearGradient(stops: [.init(color: paper.opacity(0), location: 0), .init(color: paper, location: fade / (bottom + fade)), .init(color: paper, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: bottom + fade)
                .offset(y: proxy.size.height - bottom - fade)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func probes(_ layout: ReaderLayout) -> some View {
        if LaunchOptions.isUITest {
            Text("visible text")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.visibleText")
                .accessibilityValue(model.visibleTextProbe)
                .allowsHitTesting(false)
            Text(model.anchorCheck)
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.anchorCheck")
                .accessibilityLabel(model.anchorCheck)
                .accessibilityValue(model.anchorDetail)
                .allowsHitTesting(false)
            Text(layout.posture.rawValue)
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.posture")
                .accessibilityLabel(layout.posture.rawValue)
                .allowsHitTesting(false)
            // UI tests switch posture at runtime, so one test can walk every posture.
            HStack(spacing: 0) {
                ForEach(Posture.allCases, id: \.self) { posture in
                    Button {
                        readerLog.notice("debug posture \(posture.rawValue, privacy: .public)")
                        forced = posture
                    } label: {
                        Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel(posture.rawValue)
                    .accessibilityIdentifier("debug.posture.\(posture.rawValue)")
                }
            }
            .offset(y: layout.pageFrame.height * 0.45)
        }
    }

    /// A single page on a wide screen keeps a book's measure (about 66 characters) with side margins.
    static func measured(_ layout: ReaderLayout, fontScale: Double) -> ReaderLayout {
        guard layout.posture == .single else { return layout }
        let inset = Measure.sideInset(width: layout.pageFrame.width, fontScale: fontScale)
        guard inset > 0 else { return layout }
        var out = layout
        out.pageFrame = layout.pageFrame.insetBy(dx: inset, dy: 0)
        return out
    }

    /// How far down the page its first line sits: Readium's inset, pushed below anything the system
    /// covers at the top (the folded Duo's camera).
    func pageTopClearance(_ layout: ReaderLayout, clearance: ChromeClearance) -> CGFloat {
        PageSafeArea.textTopInset
    }

    /// The resolved layout, measured, with its first line clear of the status bar and camera.
    /// `bare` is a page with the status bar hidden: only then does the system report the page's own
    /// clearance (with the status bar up, the folded Duo's status column reaches twice as far down).
    static func placed(_ input: LayoutInput, fontScale: Double, proxy: GeometryProxy, bare: Bool) -> ReaderLayout {
        let layout = measured(ReaderLayoutResolver.resolve(input), fontScale: fontScale)
        guard layout.deck == nil else { return layout }
        // The status column's taller report belongs to the status bar, which a bare page hides.
        let occlusions = FoldReader.occlusions(in: proxy).filter { $0.height <= 120 }
        let fresh = PageSafeArea.clearingTop(layout, safeTop: proxy.safeAreaInsets.top, occlusions: occlusions).pageFrame.minY - layout.pageFrame.minY
        let shift = PageTop.settled(fresh, known: bare && !occlusions.isEmpty, size: proxy.size, posture: layout.posture)
        return PageSafeArea.shifted(layout, by: shift)
    }

    private func ribbonX(_ layout: ReaderLayout, clearance: ChromeClearance) -> CGFloat {
        if let gutter = layout.gutter {
            return gutter.maxX + 6
        }
        return clearance.ribbonX(pageMaxX: layout.pageFrame.maxX, ribbonWidth: Ribbon.width)
    }

    private func unfold() {
        leafFolding = false
        guard !reduceMotion else {
            leafAngle = 0
            leafOpacity = 1
            withAnimation(.easeOut(duration: 0.35).delay(0.3)) { leafOpacity = 0 }
            return
        }
        leafAngle = -70
        leafOpacity = 1
        withAnimation(.spring(duration: 0.45, bounce: 0.1)) { leafAngle = 0 }
        withAnimation(.easeOut(duration: 0.3)) { spineBoost = 0.35 }
        withAnimation(.easeInOut(duration: 0.5).delay(0.35)) { spineBoost = 0 }
        // The reflow has laid out the right page by now; the paper gives way to it.
        withAnimation(.easeOut(duration: 0.28).delay(0.5)) { leafOpacity = 0 }
    }

    private func fold() {
        leafFolding = true
        leafAngle = 0
        leafOpacity = 1
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { leafOpacity = 0 }
        } else {
            withAnimation(.easeIn(duration: 0.45)) { leafAngle = -70 }
            withAnimation(.easeIn(duration: 0.2).delay(0.3)) { leafOpacity = 0 }
        }
    }

    /// Screenshots and films: flip the posture on a timer, as if the phone were opened.
    private func flipForFilming() async {
        if LaunchOptions.showEnd {
            try? await Task.sleep(for: .seconds(3))
            model.reachedEnd()
        }
        guard let after = LaunchOptions.flipAfter else { return }
        let before = forced
        try? await Task.sleep(for: .seconds(after))
        forced = LaunchOptions.flipTo
        guard let back = LaunchOptions.flipBackAfter else { return }
        try? await Task.sleep(for: .seconds(back))
        forced = before ?? .single
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

/// A silk ribbon that drops onto the page when it's bookmarked: a two-step bounce and one sway,
/// and a light tap as it settles. Swipe it up to take it out.
struct Ribbon: View {
    static let width: CGFloat = 20
    let isOn: Bool
    let color: Color
    var onRemove: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drops = 0
    @State private var lift: CGFloat = 0

    private struct Fall {
        var y: CGFloat = 0
        var sway: Double = 0
    }

    var body: some View {
        RibbonShape()
            .fill(color.gradient)
            .frame(width: Self.width, height: 46)
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .keyframeAnimator(initialValue: Fall(), trigger: drops) { ribbon, fall in
                ribbon
                    .rotationEffect(.degrees(fall.sway), anchor: .top)
                    .offset(y: fall.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    if reduceMotion {
                        LinearKeyframe(0, duration: 0.01)
                    } else {
                        LinearKeyframe(-60, duration: 0.01)
                        SpringKeyframe(6, duration: 0.22, spring: .snappy)
                        SpringKeyframe(-2, duration: 0.14)
                        SpringKeyframe(0, duration: 0.16)
                    }
                }
                KeyframeTrack(\.sway) {
                    if reduceMotion {
                        LinearKeyframe(0, duration: 0.01)
                    } else {
                        LinearKeyframe(0, duration: 0.2)
                        CubicKeyframe(3, duration: 0.16)
                        CubicKeyframe(-2, duration: 0.16)
                        CubicKeyframe(0, duration: 0.18)
                    }
                }
            }
            .offset(y: isOn ? min(0, lift) : -60)
            .opacity(isOn ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3), value: isOn)
            .frame(width: 44, height: 60, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { g in if abs(g.translation.height) > abs(g.translation.width) { lift = g.translation.height } }
                    .onEnded { g in
                        if g.translation.height < -24 { onRemove() }
                        withAnimation(.spring(duration: 0.3)) { lift = 0 }
                    },
                isEnabled: isOn
            )
            .allowsHitTesting(isOn)
            .offset(x: -12)
            .onChange(of: isOn) { _, on in if on { drops += 1 } }
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

/// A book opened ahead of the tap: its page laid out exactly where the reader will show it, behind the
/// shelf, so the web view has loaded and painted by the time the cover is tapped.
struct WarmPage: View {
    let model: ReaderModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var hinge: HingeState = .none

    var body: some View {
        GeometryReader { proxy in
            let input = LayoutInput(containerSize: proxy.size, division: FoldReader.division(in: proxy), hinge: hinge, forced: LaunchOptions.forcedPosture)
            let layout = ReaderScreen.placed(input, fontScale: model.preferences.fontScale, proxy: proxy, bare: false)
            ZStack(alignment: .topLeading) {
                if let host = model.hostController {
                    ReaderHostView(controller: host)
                        .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                        .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)
                }
            }
            .onChange(of: layout, initial: true) { _, new in model.updateLayout(new, reason: .rotation) }
        }
        .ignoresSafeArea()
        .observingHinge($hinge)
        .onChange(of: colorScheme, initial: true) { _, scheme in
            let dark = scheme == .dark
            if model.systemIsDark != dark {
                model.systemIsDark = dark
                model.applyPreferences(reflow: false)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The system reports the camera a moment after the first frame, and moving the page then repaginates
/// the book mid-open. The clearance for each screen size is remembered across launches and settled once
/// per launch, so the page is placed right on its first frame and never moves under the reader.
@MainActor
enum PageTop {
    private static var settledShift: [String: CGFloat] = [:]
    private static let defaultsKey = "GatefoldPageTopShift"

    /// The clearance a bare page last reported at this size, settled once per launch.
    static func settled(_ fresh: CGFloat, known: Bool, size: CGSize, posture: Posture) -> CGFloat {
        let key = "\(Int(size.width))x\(Int(size.height))-\(posture.rawValue)"
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        let remembered = stored[key]
        if known, remembered != Double(fresh) {
            stored[key] = Double(fresh)
            UserDefaults.standard.set(stored, forKey: defaultsKey)
        }
        if let done = settledShift[key] { return done }
        if let remembered {
            settledShift[key] = CGFloat(remembered)
            return CGFloat(remembered)
        }
        if known { settledShift[key] = fresh }
        return fresh
    }
}
