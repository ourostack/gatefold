import GatefoldCore
import ReadiumShared
import SwiftUI
import UIKit

/// Your Page: a compact glass panel anchored low over the page, never a full-height sheet.
/// The top of the page stays in view above it and is never dimmed, so every theme, size and
/// brightness change shows on the page as it happens. Fine-Tune goes on, inside the same panel,
/// to the font and layout.
struct SettingsPanel: View {
    let model: ReaderModel
    /// The screen's width, for the tile grid: two rows of three on a narrow screen.
    let width: CGFloat
    let onClose: () -> Void
    @State private var customizing = LaunchOptions.sheet == "customize"
    @State private var confirmedDefault = false
    @State private var brightness = Double(Self.screen?.brightness ?? 0.5)

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    /// The pair "Match Light and Dark" follows: a light page by day, a dark one by night. A dark theme
    /// picked by hand is the night half, with Linen for the day.
    static func dayAndNight(_ prefs: ReaderPreferences) -> (day: ReaderTheme, night: ReaderTheme) {
        prefs.theme.palette.isDark ? (.vellum, prefs.theme) : (prefs.theme, prefs.darkTheme.palette.isDark ? prefs.darkTheme : .dusk)
    }

    /// Daylight, Dusk, Fog, Linen, Sage, Midnight: light and dark alternate along the row.
    static let tileOrder: [ReaderTheme] = [.daylight, .dusk, .fog, .vellum, .sage, .midnight]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Compact when it fits; on a short screen (landscape, the cover screen) the body scrolls
            // and Close stays in reach above it.
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical) { content }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .foregroundStyle(Color.primary)
        .tint(Color.primary)
        .animation(Motion.open, value: customizing)
        .sensoryFeedback(.selection, trigger: model.preferences)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.panel")
    }

    @ViewBuilder private var content: some View {
        if customizing {
            customize
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
        } else {
            main
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if customizing {
                RoundIcon(systemName: "chevron.backward", label: "Back", id: "appearance.back") { customizing = false }
            } else {
                RoundIcon(systemName: "xmark", label: "Close", id: "appearance.close", action: onClose)
            }
            Text(customizing ? "Fine-Tune" : "Your Page")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }

    // MARK: The first page

    private var main: some View {
        let prefs = model.preferences
        return VStack(spacing: 14) {
            HStack(spacing: 10) {
                SizeStepper(model: model)
                HStack(spacing: 0) {
                    Menu {
                        Picker("Page Turn", selection: Binding(
                            get: { prefs.pageTurn },
                            set: { style in model.setPreferences { $0.pageTurn = style } }
                        )) {
                            ForEach(PageTurnStyle.choices, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    } label: {
                        Image(systemName: "book.pages")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 48, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Page Turn")
                    .accessibilityValue(prefs.pageTurn.displayName)
                    .accessibilityIdentifier("appearance.pageTurn")
                    Button {
                        model.setPreferences {
                            let on = !$0.matchSystemAppearance
                            if on { ($0.theme, $0.darkTheme) = SettingsPanel.dayAndNight($0) }
                            $0.matchSystemAppearance = on
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 17, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 48, height: 44)
                            .background(prefs.matchSystemAppearance ? Color.primary.opacity(0.12) : .clear, in: .capsule)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Match Light and Dark")
                    .accessibilityValue(prefs.matchSystemAppearance ? "On" : "Off")
                    .accessibilityAddTraits(prefs.matchSystemAppearance ? .isSelected : [])
                    .accessibilityIdentifier("appearance.matchSystem")
                }
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.06), in: .capsule)
            }

            HStack(spacing: 10) {
                Image(systemName: "sun.min").accessibilityHidden(true)
                Slider(value: $brightness, in: 0...1) { Text("Brightness") }
                    .onChange(of: brightness) { _, v in Self.screen?.brightness = CGFloat(v) }
                    .accessibilityIdentifier("appearance.brightness")
                Image(systemName: "sun.max").accessibilityHidden(true)
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)

            let narrow = width < 500
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: narrow ? 3 : 6), spacing: 10) {
                ForEach(Self.tileOrder, id: \.self) { theme in
                    ThemeTile(theme: theme, font: prefs.font,
                              isSelected: prefs.matchSystemAppearance ? (theme == prefs.theme || theme == prefs.darkTheme) : theme == prefs.theme) {
                        model.setPreferences {
                            $0.theme = theme
                            $0.matchSystemAppearance = false
                        }
                    }
                }
            }
            if prefs.matchSystemAppearance {
                let pair = SettingsPanel.dayAndNight(prefs)
                Text("\(pair.day.displayName) while the sun's up, \(pair.night.displayName) once it sets")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            Button {
                customizing = true
            } label: {
                Label("Fine-Tune", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 360, minHeight: 44)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("appearance.customize")
        }
    }

    // MARK: Fine-Tune

    private func furnitureRow(_ symbol: String, _ title: String, _ id: String,
                              _ key: WritableKeyPath<ReaderPreferences, Bool>) -> some View {
        SettingRow(symbol: symbol, title: title) {
            Toggle(title, isOn: Binding(
                get: { model.preferences[keyPath: key] },
                set: { v in model.setPreferences { $0[keyPath: key] = v } }
            ))
            .labelsHidden()
            .tint(Color.ribbon)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier(id)
        }
    }

    private var customize: some View {
        let prefs = model.preferences
        return VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderFont.allCases, id: \.self) { font in
                        FontChip(font: font, isSelected: prefs.font == font) {
                            model.setPreferences { $0.font = font }
                        }
                    }
                }
            }
            SettingRow(symbol: "arrow.up.and.down.text.horizontal", title: "Line Spacing") {
                Picker("Line Spacing", selection: Binding(
                    get: { prefs.lineSpacing },
                    set: { v in model.setPreferences { $0.lineSpacing = v } }
                )) {
                    Text("Snug").tag(LineSpacing.compact).accessibilityLabel("Compact")
                    Text("Easy").tag(LineSpacing.normal).accessibilityLabel("Normal")
                    Text("Airy").tag(LineSpacing.relaxed).accessibilityLabel("Relaxed")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.lineSpacing")
            }
            SettingRow(symbol: "arrow.left.and.right.text.vertical", title: "Margins") {
                Picker("Margins", selection: Binding(
                    get: { prefs.margins },
                    set: { v in model.setPreferences { $0.margins = v } }
                )) {
                    Text("Slim").tag(PageMargins.narrow).accessibilityLabel("Narrow")
                    Text("Classic").tag(PageMargins.normal).accessibilityLabel("Normal")
                    Text("Roomy").tag(PageMargins.wide).accessibilityLabel("Wide")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.margins")
            }
            SettingRow(symbol: "text.justify", title: "Justify") {
                Toggle("Justify Text", isOn: Binding(
                    get: { prefs.justify },
                    set: { v in model.setPreferences { $0.justify = v } }
                ))
                .labelsHidden()
                .tint(Color.ribbon)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("appearance.justify")
            }
            // Page furniture: none of it moves the words, so each applies live.
            furnitureRow("number.square", "Page Numbers", "appearance.pageNumbers", \.showsPageNumbers)
            furnitureRow("location", "Position in Book", "appearance.positionLabel", \.showsPositionLabel)
            furnitureRow("hourglass", "Pages Left in Chapter", "appearance.pagesLeft", \.showsPagesLeft)
            Button {
                model.useAsDefault()
                confirmedDefault.toggle()
            } label: {
                Label(model.followsDefault ? "These Are Your Defaults" : "Use as Default for All Books",
                      systemImage: model.followsDefault ? "checkmark" : "books.vertical")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(model.followsDefault)
            .sensoryFeedback(.success, trigger: confirmedDefault)
            .accessibilityIdentifier("appearance.useAsDefault")
        }
    }
}

/// A row in Fine-Tune: a symbol that shows the setting's own axis, its name, and its control.
private struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .fixedSize()
            Spacer(minLength: 8)
            control().frame(maxWidth: 240)
        }
        .frame(minHeight: 44)
    }
}

/// Smaller and larger text: a small A and a large A in one wide capsule, a hairline between them.
private struct SizeStepper: View {
    let model: ReaderModel

    var body: some View {
        HStack(spacing: 0) {
            step(up: false)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 22)
            step(up: true)
        }
        .background(Color.primary.opacity(0.06), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text Size")
        .accessibilityValue("\(Int((model.preferences.fontScale * 100).rounded())) percent")
    }

    private func step(up: Bool) -> some View {
        Button {
            model.setPreferences { _ = $0.stepFont(up: up) }
        } label: {
            Text("A")
                .font(up ? .title3.weight(.medium) : .footnote.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(up ? "Larger Text" : "Smaller Text")
        .accessibilityIdentifier("appearance.\(up ? "larger" : "smaller")")
    }
}

/// A theme as a little page: its paper, "Aa" in its ink and in the font the page will use, and its
/// name beneath. The chosen one wears a ring; no checkmark, no accent.
private struct ThemeTile: View {
    let theme: ReaderTheme
    let font: ReaderFont
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("Aa").font(FontChip.preview(font, size: 24))
                Text(theme.displayName).font(.caption2)
            }
            .foregroundStyle(theme.text)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(theme.background, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.primary : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("theme.\(theme.rawValue)")
    }
}

/// A round glass button inside the panel (the panel is glass; this is a quiet disc on it).
private struct RoundIcon: View {
    let systemName: String
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Search in the book: matches as you type, each with a little of the text around it; tap one to go there.
struct SearchSheet: View {
    let model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Locator] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty, !searching, results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(results.enumerated()), id: \.offset) { _, locator in
                    Button {
                        Task { await model.go(to: locator, rememberBack: true) }
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            (Text(locator.text.before ?? "").foregroundStyle(.secondary)
                             + Text(locator.text.highlight ?? "").bold()
                             + Text(locator.text.after ?? "").foregroundStyle(.secondary))
                                .font(.subheadline)
                                .lineLimit(3)
                            if let n = model.screenPage(atTotal: locator.locations.totalProgression ?? 0) {
                                Text("Page \(n)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("search.result")
                }
            }
            .listStyle(.plain)
            .overlay { if searching && results.isEmpty { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words in this book")
            .task(id: query) { await search() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        results = await model.search(q, limit: 60)
    }
}
