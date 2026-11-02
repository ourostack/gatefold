import GatefoldCore
import SwiftUI

/// Floating glass controls. Hidden until the middle of the page is tapped; every target is 44 pt.
struct ReaderChrome: View {
    let model: ReaderModel
    let layout: ReaderLayout
    let insets: EdgeInsets
    /// Room left for the camera and status column on the folded Duo's cover screen.
    var clearance = ChromeClearance()
    var onClose: () -> Void
    @Binding var showAppearance: Bool
    @Binding var showContents: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.chromeVisible {
                topBar
                    .padding(.leading, 16 + clearance.leading)
                    .padding(.trailing, 16 + clearance.trailing)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if layout.deck == nil {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .safeAreaPadding(.vertical, 4)
        .padding(.top, Self.safeTop(insets))
        .padding(.bottom, max(insets.bottom, 12))
        .tint(model.theme.text)
        .environment(\.glassTint, model.theme.background.opacity(0.7))
    }

    static func safeTop(_ insets: EdgeInsets) -> CGFloat { max(insets.top, 12) }
    /// The bars' heights, for the paper fade beneath them.
    static let topBarHeight: CGFloat = 4 + 8 + 44 + 8
    static let bottomBarHeight: CGFloat = 4 + 8 + 48 + 8

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

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassIconButton(systemName: "xmark", label: "Close Book", id: "reader.close", action: onClose)
            // On the cover screen the camera takes the trailing corner: Bookmark moves beside Close.
            if clearance.bookmarkLeading { bookmarkButton }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(model.title)
                    .font(.display(.subheadline))
                    .lineLimit(1)
                if let chapter = model.runningHead, chapter != model.title {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .readerGlass(model.theme.background.opacity(0.7), in: .capsule)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if !clearance.bookmarkLeading { bookmarkButton }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // After a Jump the way back stays up for a while, with or without the controls.
            if let back = model.backLocator, model.backPage != nil, model.chromeVisible || model.showJumpBack {
                Button {
                    Task { await model.goBack() }
                } label: {
                    Label("Back to page \(model.backPage ?? 0)", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                }
                .frame(minHeight: 44)
                .buttonStyle(.glass(.regular.tint(model.theme.background.opacity(0.7))))
                .accessibilityIdentifier("reader.back")
                .id(back.locations.totalProgression)
                .transition(.scale.combined(with: .opacity))
            }
            if model.chromeVisible {
            HStack(spacing: 10) {
                GlassIconButton(systemName: "list.bullet", label: "Contents and Bookmarks", id: "reader.contents") {
                    showContents = true
                }
                VStack(spacing: 2) {
                    Scrubber(model: model)
                    HStack {
                        Text(model.pageLabel)
                        Spacer()
                        if let left = model.pagesLeftLabel { Text(left) }
                    }
                    // Caption size, at 4.5:1 or better on the tinted glass in every theme.
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.theme.text.opacity(0.8))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .readerGlass(model.theme.background.opacity(0.7), in: .capsule)
                GlassIconButton(systemName: "textformat.size", label: "Appearance", id: "reader.appearance") {
                    showAppearance = true
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 720)
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
        .readerGlass(glassTint, interactive: true, in: .circle)
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
                Capsule().fill(.secondary.opacity(0.25)).frame(height: 3)
                Capsule().fill(model.theme.accent).frame(width: max(3, width * value), height: 3)
                ForEach(Array(model.chapterMap.ticks.enumerated()), id: \.offset) { _, tick in
                    Capsule().fill(.secondary.opacity(0.5)).frame(width: 1.5, height: 7)
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
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let next = min(1, max(0, g.location.x / max(1, width)))
                        if let d = dragging, model.chapterMap.crossesChapter(from: d, to: next) { crossings += 1 }
                        withAnimation(.interactiveSpring) { dragging = next }
                    }
                    .onEnded { _ in
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
        .accessibilityValue("Page \(model.pageLabel)")
        .accessibilityAdjustableAction { direction in
            let step = 0.01
            let target = model.totalProgression + (direction == .increment ? step : -step)
            Task { await model.go(toProgression: min(1, max(0, target)), rememberBack: false) }
        }
        .accessibilityIdentifier("reader.scrubber")
    }

    private func preview(at progression: Double) -> some View {
        VStack(spacing: 1) {
            Text(model.chapterMap.chapter(at: progression)?.title ?? model.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text("Page \(model.chapterMap.page(at: progression))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 180)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
                    Text(model.pagesLeftLabel ?? model.pageLabel)
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
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
