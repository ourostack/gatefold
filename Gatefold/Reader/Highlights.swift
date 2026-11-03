import GatefoldCore
import Observation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import WebKit

// Highlights and notes: the InkPad's, drawn in the book, and the reader's own, made from a text
// selection and synced back through PocketBook Cloud (whose outbox queues them while offline).

/// One highlight or note, placed in this book.
struct HighlightItem: Identifiable, Hashable {
    enum Origin: Hashable { case here, inkPad, cloud }

    var annotation: CloudAnnotation
    var range: AnnotationRange
    /// Where Readium draws it: the book's own words for the passage, with a little context.
    var locator: Locator
    var origin: Origin
    var totalProgression: Double

    /// Stable from the moment it's made, before and after the Cloud gives it a uuid.
    var id: String { annotation.dedupeKey }
    var quote: String { range.displayText }
    var note: String? { annotation.noteText }
    var date: Date? { annotation.mark?.value.created ?? annotation.quotation?.updated ?? annotation.kind.updated }

    /// "Highlighted on your InkPad · 3 days ago".
    func provenance(now: Date = Date()) -> String {
        let verb = note == nil ? "Highlighted" : "Noted"
        let place = switch origin {
        case .here: "here"
        case .inkPad: "on your InkPad"
        case .cloud: "in PocketBook Cloud"
        }
        guard let date else { return "\(verb) \(place)" }
        let age = now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return "\(verb) \(place) · \(age)"
    }
}

/// A note being written: for a fresh selection, or for a highlight already on the page.
struct NoteDraft: Identifiable {
    enum Target {
        case selection(Locator)
        case highlight(String)
    }

    let id = UUID()
    var quote: String
    var text: String
    var target: Target
}

/// The open book's highlights and notes.
@MainActor @Observable
final class HighlightStore {
    static let group: DecorationGroup = "gatefold-highlights"

    let bookID: String
    private let cloudBook: CloudBook?
    @ObservationIgnored private let sync: any SyncService

    /// In reading order.
    private(set) var items: [HighlightItem] = []
    /// The highlight whose card is up (tapped on the page).
    var active: HighlightItem?
    var draft: NoteDraft?
    /// Bumped on every new highlight, for its haptic.
    private(set) var savedCount = 0
    /// For UI tests: how many highlight boxes the page on screen has drawn.
    private(set) var drawnProbe = "drawn 0 of 0"

    @ObservationIgnored weak var model: ReaderModel?
    @ObservationIgnored private var mapper: PositionMapper?
    /// What the Cloud (or, offline, the last visit) holds, with this reader's own changes on top.
    @ObservationIgnored private var annotations: [CloudAnnotation] = []
    /// Highlights made here, so their card says so.
    @ObservationIgnored private var ours: Set<String> = []
    /// Made or removed here and not yet seen in a Cloud listing; a listing fetched before the write
    /// landed must not undo them.
    @ObservationIgnored private var recentlyAdded: Set<String> = []
    @ObservationIgnored private var recentlyRemoved: Set<String> = []
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var observingTaps = false
    @ObservationIgnored private var measure: Task<Void, Never>?
    /// Each reading-order resource's start, as a whole-book progression.
    @ObservationIgnored private var starts: [(href: String, start: Double)] = []

    init(bookID: String, cloudBook: CloudBook?, sync: any SyncService) {
        self.bookID = bookID
        self.cloudBook = cloudBook
        self.sync = sync
        Self.wipeOnceIfReset()
    }

    isolated deinit { listener?.cancel() }

    // MARK: Loading

    /// The book has its CFI mapper: draw what this device remembers, then ask the Cloud.
    func start(model: ReaderModel, mapper: PositionMapper) async {
        self.model = model
        self.mapper = mapper
        let publication = model.publication
        let positions = (try? await publication.positionsByReadingOrder().get()) ?? []
        starts = publication.readingOrder.enumerated().map { i, link in
            (link.url().removingFragment().string, i < positions.count ? positions[i].first?.locations.totalProgression ?? 0 : 1)
        }
        if let cache = JSONFile.read(Cache.self, at: cacheURL) {
            annotations = cache.annotations
            ours = cache.ours
        }
        await place()
        listen()
        await refresh()
    }

    /// Fetches the Cloud's highlights for the book (the app coming back to the foreground, or opening it).
    func refresh() async {
        guard let cloudBook, mapper != nil else { return }
        do {
            merge(server: try await sync.annotations(for: cloudBook))
            await place()
        } catch {
            readerLog.notice("highlights: kept the remembered ones (\(String(describing: error), privacy: .public))")
        }
    }

    private func listen() {
        guard listener == nil, let fastHash = cloudBook?.fastHash else { return }
        let changes = sync.changes()
        listener = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                switch change {
                case let .annotations(hash, list) where hash == fastHash:
                    self.merge(server: list)
                    await self.place()
                case let .annotationSaved(hash, saved) where hash == fastHash:
                    // The Cloud's uuid for a highlight made here, so later edits and removals reach it.
                    if let i = self.annotations.firstIndex(where: { $0.dedupeKey == saved.dedupeKey && $0.uuid == nil }) {
                        self.annotations[i].uuid = saved.uuid
                        self.saveCache()
                    }
                default:
                    break
                }
            }
        }
    }

    /// The Cloud's list wins, except for what this reader changed and the Cloud hasn't caught up with.
    private func merge(server: [CloudAnnotation]) {
        let serverKeys = Set(server.map(\.dedupeKey))
        var list = server.filter { $0.kind.value != .bookmark && !recentlyRemoved.contains($0.dedupeKey) }
        for a in annotations where recentlyAdded.contains(a.dedupeKey) && !serverKeys.contains(a.dedupeKey) { list.append(a) }
        recentlyAdded.subtract(serverKeys)
        recentlyRemoved.formIntersection(serverKeys)
        annotations = list
        saveCache()
    }

    /// Finds every annotation in the book and redraws.
    private func place() async {
        guard let mapper else { return }
        var placed: [HighlightItem] = []
        for annotation in annotations {
            guard let range = await mapper.range(for: annotation), let locator = locator(for: range) else { continue }
            let key = annotation.dedupeKey
            let origin: HighlightItem.Origin = ours.contains(key) ? .here
                : [.device, .external].contains(annotation.anchorStyle) ? .inkPad : .cloud
            placed.append(HighlightItem(annotation: annotation, range: range, locator: locator, origin: origin,
                                        totalProgression: locator.locations.totalProgression ?? 0))
        }
        items = placed.sorted { ($0.totalProgression, $0.range.progression) < ($1.totalProgression, $1.range.progression) }
        if let active, !items.contains(where: { $0.id == active.id }) { self.active = nil }
        draw()
    }

    private func locator(for range: AnnotationRange) -> Locator? {
        guard let publication = model?.publication,
              let index = publication.readingOrder.firstIndex(where: { ContentsIndex.sameResource($0.url().removingFragment().string, range.href) })
        else { return nil }
        let link = publication.readingOrder[index]
        let start = index < starts.count ? starts[index].start : 0
        let next = index + 1 < starts.count ? starts[index + 1].start : 1
        return Locator(
            href: link.url().removingFragment(), mediaType: link.mediaType ?? .xhtml,
            locations: .init(progression: range.progression, totalProgression: start + (next - start) * range.progression),
            text: .init(after: range.after, before: range.before, highlight: range.text)
        )
    }

    // MARK: Drawing

    /// The page in view is a new navigator (the catch-up's standby page): listen to it and draw on it.
    func navigatorChanged() {
        observingTaps = false
        draw()
    }

    /// Hands the navigator every highlight in the current theme's tints.
    func draw() {
        guard let model, let host = model.host else { return }
        if !observingTaps {
            observingTaps = true
            host.navigator.observeDecorationInteractions(inGroup: Self.group) { [weak self] event in
                guard let self, let item = self.items.first(where: { $0.id == event.decoration.id }) else { return }
                readerLog.notice("highlights: tapped one (note: \(item.note != nil, privacy: .public))")
                self.active = item
            }
        }
        let theme = model.theme
        let decorations = items.map { item in
            Decoration(id: item.id, locator: item.locator,
                       style: .init(id: .gatefoldHighlight, config: HighlightLook(color: item.annotation.color?.value ?? .yellow, theme: theme, hasNote: item.note != nil,
                                                                                   here: ours.contains(item.id))))
        }
        host.navigator.apply(decorations: decorations, in: Self.group)
        measureSoon()
    }

    /// For UI tests: how many highlight boxes are on screen, and where (in window points) the first
    /// one, the first note and the lowest box sit, so a test can tap them.
    func measureSoon() {
        guard LaunchOptions.isUITest else { return }
        measure?.cancel()
        measure = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, let host = self.model?.host else { return }
            var drawn = 0
            var points: [String] = []
            for web in Self.visibleWebViews(in: host.navigator.view) {
                guard let json = await Self.evaluate(Self.probeScript, in: web),
                      let probe = try? JSONDecoder().decode(Probe.self, from: Data(json.utf8)) else { continue }
                drawn += probe.count
                for (name, xy) in [("first", probe.first), ("note", probe.note), ("lowest", probe.lowest), ("here", probe.here)] {
                    guard let xy, xy.count == 2 else { continue }
                    let p = web.convert(CGPoint(x: xy[0], y: xy[1]), to: nil)
                    points.append("\(name)=\(Int(p.x)),\(Int(p.y))")
                }
            }
            guard !Task.isCancelled else { return }
            readerLog.notice("highlights: \(drawn, privacy: .public) boxes on screen of \(self.items.count, privacy: .public) [\(points.joined(separator: ";"), privacy: .public)]")
            self.drawnProbe = "drawn \(drawn) of \(self.items.count)"
            self.drawnPoints = points.joined(separator: ";")
        }
    }

    /// For UI tests: `first=x,y;note=x,y;lowest=x,y;here=x,y` in window points (`here`: one made on
    /// this device).
    private(set) var drawnPoints = ""

    private struct Probe: Decodable {
        var count: Int
        var first: [Double]?
        var note: [Double]?
        var lowest: [Double]?
        var here: [Double]?
    }

    private static let probeScript = """
    (() => {
      const vw = window.innerWidth, vh = window.innerHeight;
      const seen = (r) => r.width > 0 && r.right > 0 && r.left < vw && r.bottom > 0 && r.top < vh;
      const rects = (q) => Array.from(document.querySelectorAll(q)).map((e) => e.getBoundingClientRect()).filter(seen);
      const mid = (r) => (r ? [r.left + r.width / 2, r.top + r.height / 2] : null);
      const all = rects('.gf-hl');
      const lowest = all.reduce((a, r) => (!a || r.top > a.top ? r : a), null);
      return JSON.stringify({ count: all.length, first: mid(all[0]), note: mid(rects('.gf-note')[0]), lowest: mid(lowest), here: mid(rects('.gf-here')[0]) });
    })()
    """

    private static func visibleWebViews(in root: UIView) -> [WKWebView] {
        var found: [WKWebView] = []
        func walk(_ v: UIView) {
            if let web = v as? WKWebView {
                if !web.isHidden, web.alpha > 0.01, web.convert(web.bounds, to: root).intersects(root.bounds) { found.append(web) }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func evaluate(_ script: String, in web: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
    }

    // MARK: Changes

    /// A new highlight (or note) on the reader's selection.
    func add(_ selection: Locator, note: String? = nil) async {
        guard let mapper, let words = selection.text.highlight, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let range = await mapper.range(href: selection.href.string, highlight: words, before: selection.text.before,
                                             after: selection.text.after, progression: selection.locations.progression) else {
            readerLog.error("highlight: the selection wasn't found in the book's XHTML")
            model?.errorMessage = "That passage slipped through our fingers. Try selecting it again?"
            return
        }
        var annotation = CloudAnnotation.highlight(range, note: note, at: Date())
        if let existing = annotations.firstIndex(where: { $0.dedupeKey == annotation.dedupeKey }) {
            // Already highlighted: a note is the only news.
            guard let note else { return }
            annotations[existing].setNote(note, at: Date())
            annotation = annotations[existing]
        } else {
            annotations.append(annotation)
            ours.insert(annotation.dedupeKey)
            recentlyAdded.insert(annotation.dedupeKey)
            savedCount += 1
        }
        recentlyRemoved.remove(annotation.dedupeKey)
        saveCache()
        await place()
        if let cloudBook { await sync.save(annotation, for: cloudBook) }
    }

    func setNote(_ text: String, for id: String) async {
        guard let i = annotations.firstIndex(where: { $0.dedupeKey == id }) else { return }
        annotations[i].setNote(text, at: Date())
        let annotation = annotations[i]
        saveCache()
        await place()
        if active?.id == id { active = items.first { $0.id == id } }
        if let cloudBook { await sync.save(annotation, for: cloudBook) }
    }

    func remove(_ id: String) async {
        guard let i = annotations.firstIndex(where: { $0.dedupeKey == id }) else { return }
        let annotation = annotations.remove(at: i)
        ours.remove(id)
        recentlyAdded.remove(id)
        recentlyRemoved.insert(id)
        if active?.id == id { active = nil }
        saveCache()
        await place()
        if let cloudBook { await sync.deleteAnnotation(annotation, for: cloudBook) }
    }

    func jump(to item: HighlightItem) async {
        await model?.go(to: item.locator, rememberBack: true)
        measureSoon()
    }

    func saveDraft(_ draft: NoteDraft) async {
        switch draft.target {
        case let .selection(locator): await add(locator, note: draft.text)
        case let .highlight(id): await setNote(draft.text, for: id)
        }
    }

    // MARK: This device's copy

    private struct Cache: Codable {
        var annotations: [CloudAnnotation]
        var ours: Set<String>
    }

    private static var directory: URL { URL.applicationSupportDirectory.appending(path: "Highlights", directoryHint: .isDirectory) }

    private var cacheURL: URL {
        let name = bookID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bookID
        return Self.directory.appending(path: "\(name).json")
    }

    private func saveCache() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        JSONFile.write(Cache(annotations: annotations, ours: ours), to: cacheURL)
    }

    private static var wiped = false

    /// A clean start (`-GatefoldReset`) forgets remembered highlights, as it forgets the shelf.
    private static func wipeOnceIfReset() {
        guard LaunchOptions.resetState, !wiped else { return }
        wiped = true
        try? FileManager.default.removeItem(at: directory)
    }
}

/// The app's copy of `GatefoldCloud`'s JSON helpers (that one is internal to the package).
private enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

// MARK: - The look on the page

/// A soft tint that reads in every theme: multiplied into light paper, screened into dark.
struct HighlightLook: Hashable {
    var fill: String
    var blend: String
    var mark: String
    var hasNote: Bool
    /// Made on this device (UI tests find it by this; it looks the same as any other).
    var here = false

    init(color: AnnotationColor, theme: ReaderTheme, hasNote: Bool, here: Bool = false) {
        let dark = theme.palette.isDark
        let family: Int = switch color {
        case .cyan, .blue: 1
        case .green, .lime: 2
        case .red, .magenta: 3
        default: 0
        }
        // Light: yellow, periwinkle, green, rose pencil. Dark: the same, as dim inks that brighten the glyphs.
        // The blue is a pencil's violet-blue, not the system's sky blue, so a highlight never reads as
        // a text selection.
        let light: [UInt32] = [0xF6E3A1, 0xCFC6EC, 0xD3EABD, 0xF5C9D1]
        let night: [UInt32] = [0x5C4A1C, 0x3A3160, 0x2A4626, 0x5A2633]
        // A highlight with a note is a warm apricot wash whatever its colour, so a note reads as
        // pencil in the margin, never as a system text selection.
        let noteLight: UInt32 = 0xF7D3AE, noteNight: UInt32 = 0x5E3B20
        fill = ThemePalette.hexString(hasNote ? (dark ? noteNight : noteLight) : (dark ? night[family] : light[family]))
        blend = dark ? "screen" : "multiply"
        mark = ThemePalette.hexString(theme.palette.accent)
        self.hasNote = hasNote
        self.here = here
    }
}

extension Decoration.Style.Id {
    static var gatefoldHighlight: Self { "gatefoldHighlight" }
}

extension HTMLDecorationTemplate {
    /// A highlighter stroke per line. A note adds a dotted underline and a ribbon dot after its last word.
    static func gatefoldHighlight() -> HTMLDecorationTemplate { HTMLDecorationTemplate(
        layout: .boxes,
        element: { decoration in
            let look = (decoration.style.config as? HighlightLook) ?? HighlightLook(color: .yellow, theme: .vellum, hasNote: false)
            return "<div class=\"gf-hl\(look.hasNote ? " gf-note" : "")\(look.here ? " gf-here" : "")\" style=\"--gf-fill: \(look.fill); --gf-blend: \(look.blend); --gf-mark: \(look.mark);\"/>"
        },
        stylesheet: """
        .gf-hl {
            box-sizing: border-box;
            border-radius: 3px;
            /* ReadiumCSS clears every background-color under a user theme; an image layer survives. */
            background-image: linear-gradient(var(--gf-fill), var(--gf-fill));
            mix-blend-mode: var(--gf-blend);
            animation: gf-ink 0.35s ease-out;
        }
        .gf-hl.gf-note { border-bottom: 1.5px dotted var(--gf-mark); }
        .gf-hl.gf-note:last-child::after {
            content: "";
            position: absolute;
            right: -8px;
            top: -3px;
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background-image: linear-gradient(var(--gf-mark), var(--gf-mark));
        }
        @keyframes gf-ink { from { opacity: 0; clip-path: inset(0 100% 0 0); } to { opacity: 1; clip-path: inset(0 0 0 0); } }
        @media (prefers-reduced-motion: reduce) { .gf-hl { animation: none; } }
        """
    ) }
}

// MARK: - The selection menu

extension ReaderHostController {
    /// The selection menu: Highlight and Note first, then the system's Copy and Look Up.
    static var highlightEditingActions: [EditingAction] {
        [
            EditingAction(title: "Highlight", action: #selector(gatefoldHighlight(_:))),
            EditingAction(title: "Note", action: #selector(gatefoldNote(_:))),
            .copy,
            .lookup,
        ]
    }

    static var highlightTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] {
        [.gatefoldHighlight: .gatefoldHighlight()]
    }

    @objc func gatefoldHighlight(_ sender: Any?) {
        guard let selection = navigator.currentSelection, let store = weakModel?.highlights else { return }
        navigator.clearSelection()
        Task { await store.add(selection.locator) }
    }

    @objc func gatefoldNote(_ sender: Any?) {
        guard let selection = navigator.currentSelection, let store = weakModel?.highlights else { return }
        navigator.clearSelection()
        let quote = AnnotationRange.foldedForDisplay(selection.locator.text.highlight ?? "")
        // Already highlighted: write on that one rather than making a twin.
        if let existing = store.items.first(where: { $0.quote == quote }) {
            store.draft = NoteDraft(quote: existing.quote, text: existing.note ?? "", target: .highlight(existing.id))
        } else {
            store.draft = NoteDraft(quote: quote, text: "", target: .selection(selection.locator))
        }
    }
}

extension AnnotationRange {
    static func foldedForDisplay(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

// MARK: - Sheets

extension View {
    /// The highlight card, the note editor, and the hidden probe the UI tests read.
    func highlightLayer(_ model: ReaderModel) -> some View { modifier(HighlightLayer(model: model)) }
}

private struct HighlightLayer: ViewModifier {
    let model: ReaderModel

    func body(content: Self.Content) -> some View {
        @Bindable var store = model.highlights
        content
            .sheet(item: $store.active) { item in
                HighlightCard(model: model, item: item)
            }
            .sheet(item: $store.draft) { draft in
                NoteEditor(model: model, draft: draft)
            }
            .onChange(of: model.theme) { store.draw() }
            .onChange(of: model.pageReady) { store.draw() }
            .onChange(of: model.location) { store.measureSoon() }
            .sensoryFeedback(.impact(weight: .light), trigger: store.savedCount)
            .overlay(alignment: .topLeading) {
                if LaunchOptions.isUITest {
                    Text(store.drawnProbe)
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .accessibilityIdentifier("reader.highlights")
                        .accessibilityLabel(store.drawnProbe)
                        .accessibilityValue(store.drawnPoints)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// What a tapped highlight says: the words, the note, where it came from; and what you can do with it.
struct HighlightCard: View {
    let model: ReaderModel
    let item: HighlightItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.provenance())
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("highlight.provenance")

            Text(item.quote)
                .font(.system(.title3, design: .serif))
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.ribbon.opacity(0.75)).frame(width: 3)
                }
                .fixedSize(horizontal: false, vertical: true)

            if let note = item.note {
                Text(note)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("highlight.note")
            }

            HStack(spacing: 12) {
                Button {
                    let store = model.highlights
                    dismiss()
                    store.draft = NoteDraft(quote: item.quote, text: item.note ?? "", target: .highlight(item.id))
                } label: {
                    Label(item.note == nil ? "Add a Note" : "Edit Note", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("highlight.editNote")

                Button(role: .destructive) {
                    let store = model.highlights
                    Task { await store.remove(item.id) }
                } label: {
                    Label("Remove", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .tint(.red)
                .accessibilityIdentifier("highlight.remove")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .frame(maxWidth: 560, alignment: .leading)
        // Centred in a wider sheet, so the card is balanced rather than hugging the left.
        .frame(maxWidth: .infinity)
        // The folded Duo reports a trailing inset for its camera corner; down here in the sheet it
        // only pushed the card left. The card keeps its own even margins instead.
        .ignoresSafeArea(.container, edges: .horizontal)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("highlight.card")
    }
}

/// A note in the margin, for a fresh selection or a highlight already there.
struct NoteEditor: View {
    let model: ReaderModel
    @State var draft: NoteDraft
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.quote)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Color.ribbon.opacity(0.75)).frame(width: 3) }
                TextEditor(text: $draft.text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .overlay(alignment: .topLeading) {
                        if draft.text.isEmpty {
                            Text("What did this make you think?")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("note.text")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .navigationTitle("A Note in the Margin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let store = model.highlights
                        let finished = draft
                        dismiss()
                        Task { await store.saveDraft(finished) }
                    }
                    .accessibilityIdentifier("note.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }
}

/// The Highlights tab of the contents sheet.
struct HighlightRows: View {
    let model: ReaderModel
    var onJump: () -> Void

    var body: some View {
        let items = model.highlights.items
        if items.isEmpty {
            ContentUnavailableView(
                "Nothing Highlighted Yet",
                systemImage: "highlighter",
                description: Text("Press and hold a line, then tap Highlight. Whatever you mark on your InkPad turns up here too.")
            )
            .listRowBackground(Color.clear)
        } else {
            ForEach(items) { item in
                Button {
                    let store = model.highlights
                    onJump()
                    Task { await store.jump(to: item) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.quote)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        if let note = item.note {
                            Label(note, systemImage: "text.bubble")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(item.provenance())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("highlights.row")
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        let store = model.highlights
                        Task { await store.remove(item.id) }
                    }
                }
            }
        }
    }
}
