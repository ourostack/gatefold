import GatefoldCore
import SwiftUI

/// Themes and type. Laid out openly: rows separated by space, not boxes.
struct AppearanceSheet: View {
    let model: ReaderModel
    @State private var confirmedDefault = false
    /// Room for the cover screen's camera when the sheet is pulled up under it.
    @State private var topClearance: CGFloat = 0

    var body: some View {
        let prefs = model.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 12) {
                    TextSizeControl(model: model, idPrefix: "appearance")
                    Spacer()
                    Picker("Page Turn", selection: Binding(
                        get: { prefs.pageTurn },
                        set: { style in model.setPreferences { $0.pageTurn = style } }
                    )) {
                        ForEach(PageTurnStyle.choices, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 210)
                    .accessibilityIdentifier("appearance.pageTurn")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme").font(.display(.headline))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                        ForEach(ReaderTheme.allCases, id: \.self) { theme in
                            ThemeSwatch(theme: theme, isSelected: prefs.theme == theme && !prefs.matchSystemAppearance) {
                                model.setPreferences {
                                    $0.theme = theme
                                    $0.matchSystemAppearance = false
                                }
                            }
                        }
                    }
                    let pair = Self.dayAndNight(prefs)
                    Toggle(isOn: Binding(
                        get: { prefs.matchSystemAppearance },
                        set: { on in
                            model.setPreferences {
                                // A dark page picked by hand becomes the night theme, with a light one for the day.
                                if on { ($0.theme, $0.darkTheme) = Self.dayAndNight($0) }
                                $0.matchSystemAppearance = on
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Match Light and Dark")
                            Text("\(pair.day.displayName) while the sun's up, \(pair.night.displayName) once it sets")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.ribbon)
                    .accessibilityIdentifier("appearance.matchSystem")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Font").font(.display(.headline))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ReaderFont.allCases, id: \.self) { font in
                                FontChip(font: font, isSelected: prefs.font == font) {
                                    model.setPreferences { $0.font = font }
                                }
                            }
                        }
                        .padding(.trailing, 24)
                    }
                    // More fonts lie past the edge: the row fades out instead of cutting a name in half.
                    .mask {
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Layout").font(.display(.headline))
                    labeled("Line Spacing") {
                        Picker("Line Spacing", selection: Binding(
                            get: { prefs.lineSpacing },
                            set: { v in model.setPreferences { $0.lineSpacing = v } }
                        )) {
                            Image(systemName: "text.alignleft").tag(LineSpacing.compact).accessibilityLabel("Compact")
                            Image(systemName: "line.3.horizontal").tag(LineSpacing.normal).accessibilityLabel("Normal")
                            Image(systemName: "text.line.first.and.arrowtriangle.forward").tag(LineSpacing.relaxed).accessibilityLabel("Relaxed")
                        }
                        .pickerStyle(.segmented)
                    }
                    labeled("Margins") {
                        Picker("Margins", selection: Binding(
                            get: { prefs.margins },
                            set: { v in model.setPreferences { $0.margins = v } }
                        )) {
                            Text("Narrow").tag(PageMargins.narrow)
                            Text("Normal").tag(PageMargins.normal)
                            Text("Wide").tag(PageMargins.wide)
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Justify Text", isOn: Binding(
                        get: { prefs.justify },
                        set: { v in model.setPreferences { $0.justify = v } }
                    ))
                    .tint(.ribbon)
                }

                Button {
                    model.useAsDefault()
                    confirmedDefault.toggle()
                } label: {
                    Label(model.followsDefault ? "These Are Your Defaults" : "Use as Default for All Books",
                          systemImage: model.followsDefault ? "checkmark" : "books.vertical")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .disabled(model.followsDefault)
                .sensoryFeedback(.success, trigger: confirmedDefault)
                .accessibilityIdentifier("appearance.useAsDefault")
            }
            .padding(.horizontal, 22)
            .padding(.top, 26 + topClearance)
            .padding(.bottom, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        // The folded Duo keeps a column at the trailing edge for its camera and clock, but only up top:
        // down here the sheet uses its full width, so it sits symmetric with the toggle at the edge.
        .ignoresSafeArea(.container, edges: .horizontal)
        .background {
            GeometryReader { geo in
                Color.clear.onGeometryChange(for: CGFloat.self) { _ in
                    // An occlusion reaching into the sheet's top: move the content down below it.
                    let reaching = FoldReader.occlusions(in: geo).filter { $0.maxY > 0 && $0.minY < 80 && $0.minX < geo.size.width }
                    return reaching.map { $0.maxY - 12 }.max().map { max(0, $0) } ?? 0
                } action: { topClearance = $0 }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: model.preferences)
        .animation(.snappy, value: model.preferences)
    }

    /// The pair "Match Light and Dark" follows: a light page by day, a dark one by night. A dark theme
    /// picked by hand is the night half, with Vellum for the day.
    static func dayAndNight(_ prefs: ReaderPreferences) -> (day: ReaderTheme, night: ReaderTheme) {
        prefs.theme.palette.isDark ? (.vellum, prefs.theme) : (prefs.theme, prefs.darkTheme.palette.isDark ? prefs.darkTheme : .dusk)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 20)
            content().frame(maxWidth: 230)
        }
    }
}

private struct ThemeSwatch: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: ReaderTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(theme.background, in: .rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            // In dark mode a dark swatch would vanish into the sheet without its edge.
                            .strokeBorder(isSelected ? Color.ribbon : Color.primary.opacity(colorScheme == .dark ? 0.25 : 0.12), lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(theme.displayName)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("theme.\(theme.rawValue)")
    }
}

private struct FontChip: View {
    let font: ReaderFont
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(font.displayName)
                .font(preview)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(isSelected ? Color.ribbon : .primary)
        }
        .buttonStyle(.glass)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("font.\(font.rawValue)")
    }

    private var preview: Font {
        switch font {
        case .original, .system: .body
        case .newYork: .system(.body, design: .serif)
        case .iowan: .custom("Iowan Old Style", size: 17, relativeTo: .body)
        case .georgia: .custom("Georgia", size: 17, relativeTo: .body)
        }
    }
}

/// Contents and bookmarks.
struct ContentsSheet: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            List {
                if tab == 0 {
                    ForEach(model.toc) { entry in
                        let current = isCurrent(entry)
                        Button {
                            Task { await model.go(to: entry) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .font(entry.level == 0 ? .body : .subheadline)
                                    .foregroundStyle(current ? Color.ribbon : .primary)
                                    .fontWeight(current ? .semibold : .regular)
                                    .padding(.leading, CGFloat(entry.level) * 16)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text("\(model.chapterMap.page(at: entry.progression))")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // The ribbon marks where you are, the way a bookmark sits in a printed contents page.
                        .overlay(alignment: .leading) {
                            if current {
                                RibbonShape().fill(Color.ribbon.gradient)
                                    .frame(width: 6, height: 22)
                                    .offset(x: -14)
                                    .accessibilityHidden(true)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityAddTraits(current ? .isSelected : [])
                        .accessibilityIdentifier(current ? "contents.current" : "contents.entry.\(entry.id)")
                        .id(entry.id)
                    }
                } else if model.bookmarks.items.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks Yet",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark at the top of a page to drop a ribbon there.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.bookmarks.items) { mark in
                        Button {
                            Task { await model.go(to: mark) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mark.title).font(.body)
                                if let text = mark.anchor.text {
                                    Text("“\(text)…”").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text("Page \(model.chapterMap.page(at: mark.totalProgression)) · \(mark.created.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.removeBookmark(mark.id) }
                        }
                    }
                }
            }
            .onAppear {
                if let current = model.toc.first(where: isCurrent) { scroller.scrollTo(current.id, anchor: .center) }
            }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab) {
                        Text("Contents").tag(0)
                        Text("Bookmarks").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func isCurrent(_ entry: TOCEntry) -> Bool {
        model.currentTOCEntryID == entry.id
    }
}

/// Smaller and larger text, unmistakably: a small A and a large A either side of the current size,
/// in one capsule, the way Books does it.
struct TextSizeControl: View {
    let model: ReaderModel
    var idPrefix: String
    var large = false

    var body: some View {
        let scale = model.preferences.fontScale
        HStack(spacing: 0) {
            step(up: false)
            Text("\(Int((scale * 100).rounded()))%")
                .font((large ? Font.subheadline : .footnote).monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: large ? 56 : 48)
                .contentTransition(.numericText(value: scale))
                .accessibilityHidden(true)
            step(up: true)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.snappy, value: scale)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text Size")
    }

    private func step(up: Bool) -> some View {
        Button {
            model.setPreferences { _ = $0.stepFont(up: up) }
        } label: {
            Text("A")
                .font(.system(size: up ? (large ? 25 : 22) : (large ? 15 : 13), weight: .semibold, design: .serif))
                .frame(width: large ? 58 : 50, height: large ? 50 : 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(up ? "Larger Text" : "Smaller Text")
        .accessibilityIdentifier("\(idPrefix).\(up ? "larger" : "smaller")")
    }
}
