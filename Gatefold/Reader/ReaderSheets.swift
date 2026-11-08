import GatefoldCore
import SwiftUI

struct FontChip: View {
    let font: ReaderFont
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(font.displayName)
                .font(preview)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(Color.primary)
                .background(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05), in: .capsule)
                .overlay { if isSelected { Capsule().strokeBorder(Color.primary, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("font.\(font.rawValue)")
    }

    private var preview: Font { Self.preview(font, size: 17) }

    /// The font as the page will set it (Original shows the system's book face, New York).
    static func preview(_ font: ReaderFont, size: CGFloat) -> Font {
        switch font {
        case .original, .newYork: .system(size: size, design: .serif)
        case .system: .system(size: size)
        case .iowan: .custom("Iowan Old Style", size: size, relativeTo: .body)
        case .georgia: .custom("Georgia", size: size, relativeTo: .body)
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
                                if let n = model.screenPage(atTotal: entry.progression) {
                                    Text("\(n)")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // The ribbon marks where you are, the way a bookmark sits in a printed contents page.
                        .overlay(alignment: .leading) {
                            if current {
                                RibbonShape().fill(Color.ribbon)
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
                } else if tab == 2 {
                    HighlightRows(model: model) { dismiss() }
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
                                    Text(PassageQuote.quoted(text, cut: true)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text((model.screenPage(atTotal: mark.totalProgression).map { "Page \($0) · " } ?? "") + mark.created.formatted(.relative(presentation: .named)))
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
                        Text("Highlights").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("contents.done")
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
