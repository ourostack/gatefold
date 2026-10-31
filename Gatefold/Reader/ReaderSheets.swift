import GatefoldCore
import SwiftUI

/// Themes and type. Laid out openly: rows separated by space, not boxes.
struct AppearanceSheet: View {
    let model: ReaderModel
    @State private var confirmedDefault = false

    var body: some View {
        let prefs = model.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 12) {
                    sizeButton(up: false)
                    Text("\(Int((prefs.fontScale * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 52)
                        .contentTransition(.numericText())
                    sizeButton(up: true)
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
                    Toggle(isOn: Binding(
                        get: { prefs.matchSystemAppearance },
                        set: { on in model.setPreferences { $0.matchSystemAppearance = on } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Match Light and Dark")
                            Text("\(prefs.theme.displayName) by day, \(prefs.darkTheme.displayName) at night")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.ribbon)
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
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: model.preferences)
        .animation(.snappy, value: model.preferences)
    }

    private func sizeButton(up: Bool) -> some View {
        Button {
            model.setPreferences { _ = $0.stepFont(up: up) }
        } label: {
            Image(systemName: "textformat.size")
                .font(.system(size: up ? 22 : 14, weight: .semibold))
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(up ? "Larger Text" : "Smaller Text")
        .accessibilityIdentifier(up ? "appearance.larger" : "appearance.smaller")
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
                            .strokeBorder(isSelected ? Color.ribbon : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
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
            List {
                if tab == 0 {
                    ForEach(model.toc) { entry in
                        Button {
                            Task { await model.go(to: entry) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .font(entry.level == 0 ? .body : .subheadline)
                                    .foregroundStyle(isCurrent(entry) ? Color.ribbon : .primary)
                                    .fontWeight(isCurrent(entry) ? .semibold : .regular)
                                    .padding(.leading, CGFloat(entry.level) * 16)
                                Spacer()
                                Text("\(model.chapterMap.page(at: entry.progression))")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.clear)
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
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.removeBookmark(mark.id) }
                        }
                    }
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
        let level0 = model.toc.filter { $0.level == 0 }
        guard let i = model.chapterMap.chapterIndex(at: model.totalProgression), i < level0.count else { return false }
        return level0[i].id == entry.id
    }
}
