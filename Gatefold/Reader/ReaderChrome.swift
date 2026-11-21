import GatefoldCore
import OuroHX
import SwiftUI

/// The reader's controls, the way Apple Books lays them (iOS 27.2): Close at the top leading corner and Bookmark at the
/// trailing one, and along the foot the scrubber, then Contents, Share and Your Page in one capsule, and Search. They
/// stand in the bands the hardware already takes, beside the camera at the top and over the home indicator at the foot
/// (Ouro HX's `.ouroImmersiveControls`), over a page that never moves for them (gatefold build 53: the page stepped
/// back, paper hid half its words). Hidden until the middle of the page is tapped; every target is 44 pt.
struct ReaderChrome: View {
    let model: ReaderModel
    let layout: ReaderLayout
    let insets: EdgeInsets
    /// The screen's own safe area: the reader ignores it, so nothing inside it can read it.
    var screenSafeArea = EdgeInsets()
    /// What the system covers (the folded Duo's camera and status column), in the reader's points.
    var occlusions: [CGRect] = []
    var onClose: () -> Void
    @Binding var showAppearance: Bool
    @Binding var showContents: Bool
    @Binding var showSearch: Bool

    var body: some View {
        let up = model.chromeVisible && layout.deck == nil
        ZStack(alignment: .bottom) {
            // No dim and no paper under the controls: the page shows as it is, every line where it was (build 53).
            // After a Jump the way back stays up for a while without the controls, low on the page.
            if !model.chromeVisible, model.showJumpBack, model.backLocator != nil, layout.deck == nil {
                backButton
                    .padding(.bottom, max(insets.bottom, 12) + 8)
                    .transition(.scale.combined(with: .opacity))
            }
            Color.clear
                .allowsHitTesting(false)
                .ouroImmersiveControls(isPresented: model.chromeVisible, safeArea: screenSafeArea, occlusions: occlusions) {
                    HStack(spacing: 12) {
                        GlassIconButton(systemName: "xmark", label: "Close Book", id: "reader.close", action: onClose)
                        Spacer(minLength: 0)
                        bookmarkButton
                    }
                } bottom: {
                    if layout.deck == nil { bottomBar }
                }
        }
        .animation(Motion.chrome, value: up)
        .animation(Motion.chrome, value: showAppearance)
        .animation(Motion.chrome, value: model.showJumpBack)
        .tint(model.theme.text)
        .environment(\.glassTint, model.theme.background.opacity(0.7))
    }

    static func safeTop(_ insets: EdgeInsets) -> CGFloat { max(insets.top, 12) }

    /// The status bar's room in portrait, remembered from any screen that shows it. With the status bar
    /// hidden an iPhone's Dynamic Island leaves the safe area, and it isn't among the occlusion regions
    /// either, so a slip hung from the top would slide under it.
    enum StatusRoom {
        private static let key = "GatefoldStatusRoom"
        static func note(_ insets: EdgeInsets, size: CGSize) {
            guard size.height > size.width, insets.top > 20, insets.top != remembered else { return }
            UserDefaults.standard.set(Double(insets.top), forKey: key)
        }
        static var remembered: CGFloat { CGFloat(UserDefaults.standard.double(forKey: key)) }
        /// Where a slip's top may start: below the remembered room in portrait, else the safe area.
        static func slipSafeTop(_ safeTop: CGFloat, size: CGSize) -> CGFloat {
            size.height > size.width ? max(safeTop, remembered) : safeTop
        }
    }
    /// The bars' heights, for the slips that stand clear of them.
    static let topBarHeight: CGFloat = 4 + 8 + 44 + 8
    static let bottomBarHeight: CGFloat = 4 + 8 + 48 + 8

    private var backButton: some View {
        Button {
            Task { await model.goBack() }
        } label: {
            Label(model.backLabel, systemImage: "arrow.uturn.backward")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
        }
        .frame(minHeight: 44)
        .buttonStyle(.glass(.regular.tint(model.theme.background.opacity(0.7))))
        .accessibilityIdentifier("reader.back")
    }

    private var bookmarkButton: some View {
        GlassIconButton(
            systemName: model.isBookmarked ? "bookmark.fill" : "bookmark",
            label: model.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
            id: "reader.bookmark",
            tint: model.isBookmarked ? model.theme.accent : nil
        ) {
            Task { await model.toggleBookmark() }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: model.isBookmarked) { _, new in new }
        .accessibilityValue(model.isBookmarked ? "Bookmarked" : "")
    }

    /// The foot's bar: Back after a Jump, where Apple Books keeps it (lower leading), the scrubber, then the
    /// capsule of Contents, Share and Your Page, and Search.
    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 10) {
            // One pill for every way back (no identity per place): Back leaves a way back of its own, and a new
            // identity tore the tapped pill out from under his finger.
            if model.backLocator != nil {
                backButton
                    .transition(.scale.combined(with: .opacity))
            }
            if !showAppearance {
                // Where you are in the book, and a scrubber to go anywhere: a slim capsule.
                VStack(spacing: 2) {
                    Scrubber(model: model)
                    // Position and pages left are page furniture, his to show (both off by
                    // default); the scrubber still tells VoiceOver where he is.
                    if model.preferences.showsPositionLabel || model.preferences.showsPagesLeft {
                        HStack {
                            if model.preferences.showsPositionLabel { Text(model.pageLabel) }
                            Spacer()
                            if model.preferences.showsPagesLeft, let left = model.pagesLeftLabel { Text(left) }
                        }
                        // Caption size, at 4.5:1 or better on the tinted glass in every theme.
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.theme.text.opacity(0.8))
                        .accessibilityIdentifier("reader.positionLine")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 420, minHeight: 44)
                .readerGlass(model.theme.background.opacity(0.7), in: Capsule(style: .continuous))
                .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                PillButton(systemName: "list.bullet", label: "Contents and Bookmarks", id: "reader.contents") { showContents = true }
                ShareLink(item: shareLine) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
                .accessibilityIdentifier("reader.share")
                PillButton(systemName: "textformat.size", label: "Your Page", id: "reader.appearance") { showAppearance = true }
            }
            .padding(.horizontal, 4)
            .readerGlass(model.theme.background.opacity(0.7), interactive: true, in: Capsule(style: .continuous))
            GlassIconButton(systemName: "magnifyingglass", label: "Search in Book", id: "reader.search") { showSearch = true }
        }
        .foregroundStyle(model.theme.text)
    }

    /// What Share hands on: the book, its chapter, and how far along.
    private var shareLine: String {
        var line = "Reading \(model.fullTitle)"
        if let chapter = model.chapterTitle, chapter != model.title { line += ", \(chapter)" }
        return line + " (\(ReadingPercent.whole(model.totalProgression))% in), with Gatefold."
    }
}

/// One of the pill's buttons: a symbol in a 44 pt target, no glass of its own (the pill is the glass).
private struct PillButton: View {
    let systemName: String
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

struct GlassIconButton: View {
    @Environment(\.glassTint) private var glassTint
    let systemName: String
    let label: String
    let id: String
    var tint: Color?
    let action: () -> Void

    init(systemName: String, label: String, id: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.id = id
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .readerGlass(glassTint, interactive: true, in: Capsule(style: .continuous))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The progress scrubber: chapter ticks, a preview bubble while dragging, a tick of haptics at
/// each chapter boundary, and a Back button after the jump.
struct Scrubber: View {
    let model: ReaderModel
    @State private var dragging: Double?
    /// Where a finished drag is going: the thumb stays there while the page catches up.
    @State private var pending: Double?
    @State private var crossings = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let value = dragging ?? pending ?? model.totalProgression
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(.secondary.opacity(0.25)).frame(height: 3)
                Capsule(style: .continuous).fill(model.theme.accent).frame(width: max(3, width * value), height: 3)
                ForEach(Array(model.chapterMap.ticks.enumerated()), id: \.offset) { _, tick in
                    Capsule(style: .continuous).fill(.secondary.opacity(0.5)).frame(width: 1.5, height: 7)
                        .offset(x: width * tick - 0.75)
                }
                Circle()
                    .fill(model.theme.accent)
                    .frame(width: dragging == nil ? 12 : 18, height: dragging == nil ? 12 : 18)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: width * value - (dragging == nil ? 6 : 9))
                if let dragging {
                    preview(at: dragging)
                        .fixedSize()
                        .offset(x: min(max(0, width * dragging - 90), max(0, width - 180)), y: -46)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                // Only a deliberate sideways drag jumps, on lift: a touch resting on the bar, or one
                // that wobbles, leaves the page where it is (build 20 jumped on a tap).
                DragGesture(minimumDistance: ScrubberIntent.minimumDrag)
                    .onChanged { g in
                        guard dragging != nil || ScrubberIntent.isDeliberate(translation: g.translation) else { return }
                        let next = min(1, max(0, g.location.x / max(1, width)))
                        if let d = dragging, model.chapterMap.crossesChapter(from: d, to: next) { crossings += 1 }
                        withAnimation(.interactiveSpring) { dragging = next }
                    }
                    .onEnded { _ in
                        // Only a drag that became deliberate has a target; it lands where he lifts.
                        guard let target = dragging else { return }
                        pending = target
                        dragging = nil
                        Task {
                            await model.go(toProgression: target, rememberBack: true)
                            pending = nil
                        }
                    }
            )
            .sensoryFeedback(.selection, trigger: crossings)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(model.pageLabel.isEmpty ? "\(Int((model.totalProgression * 100).rounded())) percent" : "Page \(model.pageLabel)")
        .accessibilityAdjustableAction { direction in
            Task { await model.adjustScrubber(forward: direction == .increment) }
        }
        .accessibilityIdentifier("reader.scrubber")
    }

    private func preview(at progression: Double) -> some View {
        VStack(spacing: 1) {
            Text(model.chapterMap.chapter(at: progression)?.title ?? model.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if let n = model.screenPage(atTotal: progression) {
                Text("Page \(n)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 180)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Tabletop: the page above the fold, everything you tap below it (Apple: "tappable controls at the bottom").
struct TabletopDeck: View {
    let model: ReaderModel
    @Binding var showAppearance: Bool
    @Binding var showContents: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                deckButton("chevron.left", "Previous Page", "deck.previous") { model.host?.turn(forward: false) }
                VStack(spacing: 6) {
                    Text(model.chapterTitle ?? model.title)
                        .font(.display(.headline))
                        .lineLimit(1)
                    Text((model.preferences.showsPagesLeft ? model.pagesLeftLabel : nil)
                         ?? (model.preferences.showsPositionLabel ? model.pageLabel : ""))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                deckButton("chevron.right", "Next Page", "deck.next") { model.host?.turn(forward: true) }
            }
            Scrubber(model: model)
                .padding(.horizontal, 8)
            HStack(spacing: 22) {
                GlassIconButton(systemName: "list.bullet", label: "Contents", id: "deck.contents") { showContents = true }
                TextSizeControl(model: model, idPrefix: "deck", large: true)
                GlassIconButton(
                    systemName: model.isBookmarked ? "bookmark.fill" : "bookmark",
                    label: "Bookmark",
                    id: "deck.bookmark",
                    tint: model.isBookmarked ? model.theme.accent : nil
                ) { Task { await model.toggleBookmark() } }
                GlassIconButton(systemName: "circle.lefthalf.filled", label: "Appearance", id: "deck.appearance") { showAppearance = true }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(model.theme.background.mix(with: model.theme.text, by: 0.04))
        .foregroundStyle(model.theme.text)
        .tint(model.theme.text)
        .sensoryFeedback(.selection, trigger: model.preferences.fontScale)
    }

    private func deckButton(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
