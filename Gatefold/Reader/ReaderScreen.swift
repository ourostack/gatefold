import GatefoldCore
import SwiftUI

/// The reading screen: the page, laid out for the posture, with chrome that stays out of the way.
struct ReaderScreen: View {
    let model: ReaderModel
    var onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hinge: HingeState = .none
    @State private var showAppearance = LaunchOptions.sheet == "appearance" || LaunchOptions.sheet == "customize"
    @State private var showContents = LaunchOptions.sheet == "contents"
    @State private var showSearch = LaunchOptions.sheet == "search"
    /// A posture forced for screenshots and UI tests; nil follows the device.
    @State private var forced: Posture? = LaunchOptions.forcedPosture
    /// The unfold leaf: its angle about the spine, and how much of it shows.
    @State private var leafAngle = 0.0
    @State private var leafOpacity = 0.0
    @State private var leafFolding = false
    /// On the cover screen the status column sits on the page's trailing edge; it stays hidden there.
    @State private var coverScreen = false
    @State private var slipHeight: CGFloat = 0
    /// Where the line the bottom paper would reach begins (global points), when there is one.
    @State private var footerLine: CGFloat?

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
            // An open "ahead" offer gets its own band: the page slides down below it, its foot fading
            // at the screen's edge, and slides back when the offer folds. No line sits under the slip.
            let aheadOpen = model.slip != nil && model.slipKind == .ahead && !model.slipFolded && !model.chromeVisible && layout.deck == nil
            // A slip hangs below the camera as well as the status bar's room: with the status bar hidden,
            // a Dynamic Island leaves the safe area but stays among the occlusions (the 6.9" iPhone's
            // island sat on the catch-up offer). On an iPhone the island isn't an occlusion, so the slip
            // also keeps below the status bar's room as last seen in portrait.
            let slipWidth = min(proxy.size.width - 32 - clearance.leading - clearance.trailing, 460)
            let slipX = layout.gutter.map { g in g.maxX + (proxy.size.width - g.maxX - slipWidth) / 2 } ?? (proxy.size.width - slipWidth) / 2
            let slipTop = PageSafeArea.slipTop(safeTop: ReaderChrome.StatusRoom.slipSafeTop(safeTop, size: proxy.size), occlusions: FoldReader.occlusions(in: proxy), span: slipX...(slipX + max(1, slipWidth)))
            let push: CGFloat = aheadOpen
                ? max(0, slipTop + slipHeight + 14 - (layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance)))
                : 0
            // The page steps back while the controls or a slip are up, so nothing sits on its text.
            let lifted = (model.chromeVisible && layout.deck == nil) || (model.slip != nil && !model.slipFolded && push == 0)
            // A tall iPad page shrinks little at its top: with the controls up it lifts about a lower
            // anchor so its first line clears the title capsule. The Duo's placement already clears its
            // bars (and its status column), so it keeps the plain lift.
            let chromeLift = UIDevice.current.userInterfaceIdiom == .pad && model.chromeVisible && layout.deck == nil && push == 0
                ? PageSafeArea.chromeLift(textTop: layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance),
                                          height: proxy.size.height, barBottom: safeTop + ReaderChrome.topBarHeight)
                : PageSafeArea.Lift(scale: 0.96, anchorY: 0.5)
            // Reduce Motion drops the plain lift, but not one that keeps a line out from under the capsule.
            let liftNeeded = chromeLift.anchorY != 0.5
            ZStack(alignment: .topLeading) {
                model.theme.background

                page(layout, clearance: clearance)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .scaleEffect(lifted && (!reduceMotion || liftNeeded) ? chromeLift.scale : 1,
                                 anchor: UnitPoint(x: 0.5, y: chromeLift.anchorY))
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.25), value: lifted)
                    .offset(y: push)
                    .mask {
                        let h = max(proxy.size.height, 1)
                        LinearGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: push > 0 ? max(0, (h - 44) / h) : 1),
                                               .init(color: push > 0 ? .clear : .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.1), value: push)

                scrims(proxy: proxy, layout: layout, safeTop: safeTop)
                    .task(id: "\(footerNeed(proxy: proxy, layout: layout))-\(model.totalProgression)-\(model.location?.href.string ?? "")-\(model.location?.locations.progression ?? -1)-\(proxy.size.width)x\(proxy.size.height)-\(model.pageReady)") {
                        // Let a turn or a reflow settle before reading where the lines are; then again
                        // as a jump's veil lifts and its page settles on the words (the lines move, or
                        // were hidden at the first look), so the paper never ends across a line.
                        for wait in [120, 600, 1400] {
                            try? await Task.sleep(for: .milliseconds(wait))
                            guard !Task.isCancelled else { return }
                            await measureFooterLine(proxy: proxy, layout: layout)
                        }
                    }

                runningHead(layout: layout, proxy: proxy, clearance: clearance, hidden: aheadOpen || (model.chromeVisible && layout.deck == nil))
                    .task(id: headState(layout: layout, proxy: proxy, clearance: clearance, hidden: aheadOpen || (model.chromeVisible && layout.deck == nil))) {
                        readerLog.notice("running head: \(headState(layout: layout, proxy: proxy, clearance: clearance, hidden: aheadOpen || (model.chromeVisible && layout.deck == nil)), privacy: .public)")
                    }

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
                    showContents: $showContents,
                    showSearch: $showSearch
                )
                .frame(width: proxy.size.width, height: layout.deck == nil ? proxy.size.height : layout.pageFrame.height)

                if showAppearance {
                    // Low over the page (or the spread), inside the safe area, the top of the page in view.
                    SettingsPanel(model: model, width: proxy.size.width) { showAppearance = false }
                        .frame(maxWidth: 560)
                        // A height cap takes all the room it's offered, so its own alignment decides
                        // where the panel sits in it: the foot (build 14 centred it, mid-screen on the
                        // folded Duo, 120 pt above the screen's foot).
                        .frame(maxHeight: max(200, proxy.size.height - max(proxy.safeAreaInsets.top, 16) - max(proxy.safeAreaInsets.bottom, 16) - 16),
                               alignment: .bottom)
                        .padding(.leading, 16 + max(proxy.safeAreaInsets.leading, clearance.leading))
                        .padding(.trailing, 16 + max(proxy.safeAreaInsets.trailing, clearance.trailing))
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 16))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                        // It grows out of the pill's corner, where Your Page was tapped.
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
                        .zIndex(5)
                }

                if let tab = model.aheadTab, model.slipFolded, model.slip != nil {
                    // Hangs from the page's top edge in its margin, beside the binding: never on a line.
                    AheadTab(label: tab, theme: model.theme) { model.unfoldSlip() }
                        .offset(x: layout.pageFrame.minX + 16, y: layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance) - 22)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .zIndex(2)
                }

                if let slip = model.slip, let kind = model.slipKind, !model.slipFolded {
                    let width = slipWidth
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
                        x: slipX,
                        y: kind == .landed
                            ? proxy.size.height - slipBottomBand(proxy) - slipHeight
                            : (model.chromeVisible ? safeTop + 8 + ReaderChrome.topBarHeight : slipTop)
                    )
                    .animation(Motion.chrome, value: model.chromeVisible)
                    .transition(reduceMotion ? .opacity : .move(edge: kind == .landed ? .bottom : .top).combined(with: .opacity))
                    .zIndex(2)
                }

                if let picture = model.reopenPicture {
                    // Reopened at launch: his page as he left it, until the live one is laid out beneath.
                    ReopenPictureView(image: picture, leaf: model.reopenLeaf, isSpread: model.reopenSpread, theme: model.theme,
                                      curl: model.reopenCurl) { model.queueReopenTurn(forward: $0) }
                        .transition(model.reopenFades ? .opacity : .identity)
                        .zIndex(3)
                } else if !model.pageReady {
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
        .onChange(of: hinge) { old, new in
            // The hinge has started to move: hold a picture of the page before a Duo moves the app
            // to its other screen, so the unfold swings from the page he was reading.
            if model.layout.posture != .spread, old != new { model.host?.holdPageForUnfold() }
        }
        .preferredColorScheme(model.theme.colorScheme)
        // The catch-up tab hangs in the page's top margin, where the status bar prints: while it's up
        // the status bar stays hidden, chrome or not, the way Apple Books keeps its page top clear
        // (build 14 printed the time over "InkPad +56" on the iPad).
        .statusBarHidden(statusBarHidden)
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.open, value: showAppearance)
        .sheet(isPresented: $showSearch) {
            SearchSheet(model: model)
        }
        .sheet(isPresented: $showContents) {
            ContentsSheet(model: model)
        }
        .highlightLayer(model)
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
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: PostureBell.rang)) { _ in turnPosture() }
        .task { await turnPostureOnTimer() }
        #endif
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

            // The spread is plain paper: the two pages meet with nothing between them but their margins.
            if layout.gutter == nil, leafFolding, leafOpacity > 0 {
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
        // Without the controls the page moves out of the ahead slip's way (see `push`), so it needs no paper.
        let aheadSlip = model.slip != nil && model.slipKind == .ahead && !model.slipFolded && model.chromeVisible
        let top = safeTop + (model.chromeVisible ? ReaderChrome.topBarHeight : 0) + (aheadSlip ? 8 + slipHeight + 16 : 0)
        if model.chromeVisible || aheadSlip {
            LinearGradient(stops: [.init(color: paper, location: 0), .init(color: paper, location: top / (top + fade)), .init(color: paper.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: proxy.size.width, height: top + fade)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
        let bottom = footerNeed(proxy: proxy, layout: layout)
        if bottom > 0 {
            // The paper ends in the gap above the first line it would reach, so no line is ever half
            // covered or half faded beside the Back pill or under the bar. Until that line is measured
            // (a moment, while the footer fades in) it ends where it must.
            let need = proxy.size.height - bottom
            let top = footerLine.map { min(need, $0 - proxy.frame(in: .global).minY) } ?? need
            paper
                .frame(width: proxy.size.width, height: proxy.size.height - top)
                .offset(y: top)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// How much of the screen's foot the bottom paper must cover (0: none).
    private func footerNeed(proxy: GeometryProxy, layout: ReaderLayout) -> CGFloat {
        let landedSlip = model.slip != nil && model.slipKind == .landed
        let backAlone = model.showJumpBack && !model.chromeVisible && layout.deck == nil && model.backLocator != nil
        guard (model.chromeVisible && layout.deck == nil) || landedSlip || backAlone else { return 0 }
        return max(
            model.chromeVisible && layout.deck == nil ? max(proxy.safeAreaInsets.bottom, 12) + ReaderChrome.bottomBarHeight + (model.backLocator != nil ? 52 : 0) : 0,
            // After a Jump the Back pill gets its own paper footer: it never sits on a line.
            backAlone ? max(proxy.safeAreaInsets.bottom, 12) + 52 : 0,
            landedSlip ? slipBottomBand(proxy) + slipHeight + 16 : 0
        )
    }

    /// Measures the line the bottom paper would reach, whenever the paper or the page changes.
    private func measureFooterLine(proxy: GeometryProxy, layout: ReaderLayout) async {
        let bottom = footerNeed(proxy: proxy, layout: layout)
        guard bottom > 0 else { footerLine = nil; return }
        let global = proxy.frame(in: .global)
        let need = global.minY + proxy.size.height - bottom
        let line = await model.host?.lineTop(crossing: (need - 1)...(need + 1))
        readerLog.notice("footer paper: needs \(need, privacy: .public), line measured at \(line.map { "\($0)" } ?? "none", privacy: .public)")
        withAnimation(.easeOut(duration: 0.15)) { footerLine = line }
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
            Text("page count")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.pageCount")
                .accessibilityValue(model.screenPages?.total.map(String.init) ?? "")
                .allowsHitTesting(false)
            Text("number delay")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.numberDelay")
                .accessibilityValue(model.firstNumberDelay.map { String(format: "%.2f", $0) } ?? "")
                .allowsHitTesting(false)
            Text("ready")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.pageReady")
                .accessibilityValue(model.pageReady ? "1" : "0")
                .allowsHitTesting(false)
            Text("underline")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.underline")
                .accessibilityValue(model.underlineProbe)
                .allowsHitTesting(false)
            Text(model.anchorCheck)
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.anchorCheck")
                .accessibilityLabel(model.anchorCheck)
                .accessibilityValue(model.anchorDetail)
                .allowsHitTesting(false)
            Text("turn placement")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.turnPlacement")
                .accessibilityLabel(model.turnPlacement)
                .allowsHitTesting(false)
            Text("status bar")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.statusBar")
                .accessibilityLabel(statusBarHidden ? "hidden" : "shown")
                .allowsHitTesting(false)
            Text("turn settle")
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("reader.turnSettle")
                .accessibilityLabel(model.turnSettle)
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
    /// The cover screen keeps a band above the text clear of the camera. A printed book's head margin
    /// carries its running head; so does this band: the chapter in small capitals, beside the camera,
    /// never under it.
    /// Why the running head is or isn't up, for the log.
    private func headState(layout: ReaderLayout, proxy: GeometryProxy, clearance: ChromeClearance, hidden: Bool) -> String {
        let camera = FoldReader.occlusions(in: proxy).filter { $0.height <= 120 && $0.minY < 80 }.min { $0.minY < $1.minY }
        let textTop = layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance)
        guard layout.deck == nil, let camera else { return "none (no camera band)" }
        if textTop - camera.maxY < -camera.height / 2 || textTop < 40 { return "none (text top \(Int(textTop)), camera \(Int(camera.minY))-\(Int(camera.maxY)))" }
        if hidden { return "hidden (chrome or slip)" }
        if !model.pageReady { return "hidden (page not ready)" }
        return "shown"
    }

    @ViewBuilder
    private func runningHead(layout: ReaderLayout, proxy: GeometryProxy, clearance: ChromeClearance, hidden: Bool) -> some View {
        let camera = FoldReader.occlusions(in: proxy).filter { $0.height <= 120 && $0.minY < 80 }.min { $0.minY < $1.minY }
        let textTop = layout.pageFrame.minY + pageTopClearance(layout, clearance: clearance)
        let side: CGFloat = 24
        if layout.deck == nil, let camera, textTop - camera.maxY >= -camera.height / 2, textTop >= 40,
           let words = model.runningHead ?? Optional(model.title) {
            // Clear of the folded "read on" tab, which hangs at the page's leading edge in this band.
            let tab: CGFloat = model.aheadTab != nil && model.slipFolded && model.slip != nil ? 16 + 112 : 0
            // Whichever side of the camera has the more room.
            let left = (layout.pageFrame.minX + max(side, tab), min(layout.pageFrame.maxX - side, camera.minX - 14))
            let right = (max(layout.pageFrame.minX + side, camera.maxX + 14), layout.pageFrame.maxX - side)
            let (start, end) = left.1 - left.0 >= right.1 - right.0 ? left : right
            Text(words)
                .font(.caption)
                .foregroundStyle(model.theme.head)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: max(0, end - start), height: camera.height, alignment: .leading)
                .offset(x: start, y: camera.minY)
                .opacity(hidden || !model.pageReady ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: hidden)
                // Quick enough to finish as a riffle's last leaf does (`riffleLeaves`).
                .animation(.easeOut(duration: 0.18), value: words)
                .allowsHitTesting(false)
                .accessibilityIdentifier("reader.runningHead")
                .accessibilityLabel(words)
            pageNumbers(pages: [layout.pageFrame], hidden: hidden)
        } else if layout.deck == nil {
            pageFurniture(layout: layout, hidden: hidden)
        }
    }

    /// A page number centred in the band under each page's words: the pages he sees, numbered through
    /// the book at this layout (`ScreenPageMap`). Until they're counted the slot says "Counting pages…",
    /// and a blank page (the unfold's verso, a chapter's last right page) has none.
    @ViewBuilder
    private func pageNumbers(pages: [CGRect], hidden: Bool) -> some View {
        let band = model.textBand.bottom
        if model.preferences.showsPageNumbers, let numbers = model.screenNumbers, numbers.count == pages.count {
            ZStack(alignment: .topLeading) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, r in
                    if let n = numbers[i] {
                        Text("\(n)")
                            .font(model.tabletBands.map { .system(size: $0.folioSize).monospacedDigit() } ?? .caption.monospacedDigit())
                            .foregroundStyle(model.theme.head)
                            .frame(width: r.width, height: band)
                            .offset(x: r.minX, y: r.maxY - band)
                            .accessibilityIdentifier("reader.pageNumber")
                    }
                }
            }
            .opacity(hidden || !model.pageReady ? 0 : 1)
            .animation(.easeOut(duration: 0.25), value: hidden)
            .allowsHitTesting(false)
        } else if model.preferences.showsPageNumbers, model.countingPages, let first = pages.first, let last = pages.last {
            // Where the number will be, in its face and grey, a little fainter: one line under the
            // page (or centred under the spread). Drawn over the band, so the words never move.
            let r = first.union(last)
            Text("Counting pages…")
                .font(model.tabletBands.map { .system(size: $0.folioSize) } ?? .caption)
                .foregroundStyle(model.theme.head.opacity(0.7))
                .lineLimit(1)
                .frame(width: r.width, height: band)
                .offset(x: r.minX, y: r.maxY - band)
                .opacity(hidden ? 0 : 1)
                .animation(.easeOut(duration: 0.25), value: hidden)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityLabel("Counting pages")
                .accessibilityIdentifier("reader.pageCounting")
        }
    }

    /// Running heads and page numbers, the way a printed page carries them: quiet grey SF centred in
    /// the bands above and below the words. On a spread the left page is headed with the book, the
    /// right with the chapter; a single page with the chapter. A spread's numbers are two in a row.
    @ViewBuilder
    private func pageFurniture(layout: ReaderLayout, hidden: Bool) -> some View {
        let band = model.textBand
        let frame = layout.pageFrame
        let pages: [CGRect] = layout.gutter.map { g in
            [CGRect(x: frame.minX, y: frame.minY, width: g.midX - frame.minX, height: frame.height),
             CGRect(x: g.midX, y: frame.minY, width: frame.maxX - g.midX, height: frame.height)]
        } ?? [frame]
        let chapter = model.runningHead ?? model.title
        let heads = pages.count == 2 ? [model.title, chapter] : [chapter]
        ZStack(alignment: .topLeading) {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, r in
                Text(heads[i])
                    .font(model.tabletBands.map { .system(size: $0.headSize) } ?? .caption)
                    .foregroundStyle(model.theme.head)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(0, r.width - 96), height: band.top)
                    .offset(x: r.minX + 48, y: r.minY)
                    .accessibilityIdentifier(i == pages.count - 1 ? "reader.runningHead" : "reader.runningHead.book")
                    .accessibilityLabel(heads[i])
            }
            pageNumbers(pages: pages, hidden: false)
        }
        .opacity(hidden || !model.pageReady ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: hidden)
        .animation(.easeOut(duration: 0.18), value: chapter)
        .allowsHitTesting(false)
    }

    private var catchUpTabShowing: Bool { model.aheadTab != nil && model.slipFolded && model.slip != nil }
    private var statusBarHidden: Bool { !model.chromeVisible || coverScreen || catchUpTabShowing }

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

    /// The unfold itself is the host's: it swings a picture of the laid-out right page open from the
    /// spine once the spread is ready (`ReaderHostController.swingOpen`).
    private func unfold() {
        leafFolding = false
        leafOpacity = 0
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

    #if DEBUG
    /// Filming without a hinge: each ring (`notifyutil -p \(PostureBell.name)` in the simulator, or the
    /// `GatefoldPostureEvery` timer) moves to the next posture, folded → spread → tabletop → folded,
    /// through the same layout change a real hinge drives.
    private func turnPosture() {
        let cycle: [Posture] = [.single, .spread, .tabletop]
        let now = forced ?? .single
        let next = cycle[((cycle.firstIndex(of: now) ?? 0) + 1) % cycle.count]
        readerLog.notice("posture bell: \(now.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
        // A real hinge's first movement holds a picture of the page before the window moves; the bell
        // does the same, and lets the posture change only once the picture is held.
        Task {
            if next == .spread { await model.host?.holdPage() }
            hinge = next == .tabletop ? .partiallyOpen(angleDegrees: 110) : .none
            forced = next
        }
    }

    private func turnPostureOnTimer() async {
        PostureBell.listen()
        guard let every = LaunchOptions.postureEvery else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(every))
            guard !Task.isCancelled else { return }
            turnPosture()
        }
    }
    #endif

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
    static func settled(_ fresh: CGFloat, known: Bool, size: CGSize, posture: Posture,
                        active: Bool = UIApplication.shared.applicationState == .active) -> CGFloat {
        let key = "\(Int(size.width))x\(Int(size.height))-\(posture.rawValue)"
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        let remembered = stored[key]
        // Only a reading he could be looking at is remembered: once Gatefold leaves, iOS lays it out
        // again for the app switcher (status bar up, transient sizes), and remembering that cut the next
        // launch's pages a line shorter than the ones he read, so a reopen landed before his page.
        if known, active, remembered != Double(fresh) {
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

    /// A new launch: what this one settled on is forgotten, what it remembered is kept.
    static func forgetLaunch() { settledShift = [:] }

    /// A clean start (`-GatefoldReset`): nothing settled and nothing remembered.
    static func forgetEverything() {
        settledShift = [:]
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
