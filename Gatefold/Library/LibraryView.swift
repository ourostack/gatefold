import GatefoldCore
import SwiftUI
import UniformTypeIdentifiers


/// The shelf: Reading Now across the top, then everything.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    var namespace: Namespace.ID
    var onOpen: (LibraryBook) -> Void

    @State private var importing = false
    @State private var importedCount = 0
    @State private var confirmSignOut = false
    @State private var reconnecting = false
    /// How far the header moves down so the cover screen's camera and status column never sit on it.
    @State private var headerDrop: CGFloat = 0
    @State private var width: CGFloat = 0
    /// The system keeps a column at the trailing edge (the folded Duo's camera and status column).
    @State private var trailingReserved = false
    /// The shelf dropping in: how many covers have landed so far (nil once it's over). A shelf the
    /// Cloud brings drops in a cover at a time (and the first one after sign-in says hello); a shelf
    /// saved from last time is simply there at launch, no waiting.
    @State private var arrived: Int?
    @State private var greeting: String?
    @State private var arrivalTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let arrivalCap = 12
    @MainActor private static var hasDropped = false
    /// Whether the shelf saved from last time was empty at launch (set by the app before the first frame).
    @MainActor static var startedEmpty = true

    private var metrics: ShelfMetrics { ShelfMetrics.forWidth(width == 0 ? 400 : width) }

    init(namespace: Namespace.ID, onOpen: @escaping (LibraryBook) -> Void) {
        self.namespace = namespace
        self.onOpen = onOpen
        // Covers drop in only when they arrive after the shelf is up; a saved shelf shows at once.
        _arrived = State(initialValue: LibraryView.hasDropped || !LibraryView.startedEmpty ? nil : 0)
        if !LibraryView.hasDropped, !LibraryView.startedEmpty { LibraryView.hasDropped = true }
    }

    var body: some View {
        let library = app.library
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let greeting {
                        Text(greeting)
                            .font(.subheadline)
                            .foregroundStyle(Color.ink.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, metrics.gutter)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                            .accessibilityIdentifier("library.greeting")
                    }
                    if !library.books.isEmpty {
                        SyncStatusLine()
                            .padding(.horizontal, metrics.gutter)
                    }
                    switch shelfState {
                    case .books:
                        shelves
                    case .waiting:
                        Color.clear.frame(height: 200)
                    case .dusting:
                        DustingShelf(metrics: metrics)
                            .transition(.opacity)
                    case let .empty(signedIn):
                        EmptyShelf(signedIn: signedIn, onImport: { importing = true }, onConnect: { app.hasOnboarded = false })
                            .padding(.top, 48)
                            .transition(.opacity)
                    case let .unreachable(problem):
                        UnreachableShelf(problem: problem, onRetry: { Task { await app.refresh() } }, onImport: { importing = true })
                            .padding(.top, 48)
                            .transition(.opacity)
                    }
                }
                // Full width from the first frame: a shelf still waiting for its books would otherwise
                // hug the header and centre it, then jump left when the covers arrive.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Nothing shows until the shelf knows its width, so the header never flies in from a zero-wide layout.
                .opacity(width > 0 ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: shelfState)
            }
            .background(Color.paper)
            .background {
                GeometryReader { proxy in
                    Color.clear.onGeometryChange(for: [CGFloat].self) { _ in
                        // The header's band: the camera and status column at the cover screen's top corner.
                        [ChromeClearance.headerDrop(occlusions: FoldReader.occlusions(in: proxy), band: 60, width: proxy.size.width),
                         proxy.size.width, proxy.safeAreaInsets.trailing]
                    } action: { values in
                        // Measurements arrive after the first layout (the camera band later still): apply
                        // them without animation, and start from the band this screen width had last time.
                        let key = "GatefoldHeaderDrop-\(Int(values[1]))"
                        var drop = values[0]
                        if drop > 0 { UserDefaults.standard.set(Double(drop), forKey: key) }
                        else { drop = CGFloat(UserDefaults.standard.double(forKey: key)) }
                        var quiet = Transaction()
                        quiet.disablesAnimations = true
                        withTransaction(quiet) {
                            headerDrop = drop
                            width = values[1]
                            trailingReserved = values[2] > 0
                        }
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.4), trigger: arrivalTaps)
            .onChange(of: library.books.count, initial: true) { _, _ in dropIn() }
            .onChange(of: library.isRefreshing) { _, _ in dropIn() }
            // The title and buttons live in the page, so nothing floats over the covers in any posture
            // (on the Duo's cover screen the system would move bar buttons to the side edge, over the shelf).
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await app.refresh() }
            .confirmationDialog("Sign out of PocketBook Cloud?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
            } message: {
                Text("Books you've downloaded, and your place in each, stay right here.")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                Task {
                    let added = await library.importBooks(from: urls)
                    importedCount += added.count
                }
            }
            .sensoryFeedback(.success, trigger: importedCount)
            .alert("Couldn't Add That", isPresented: .constant(library.lastError != nil)) {
                Button("OK") { library.lastError = nil }
            } message: {
                Text(library.lastError ?? "")
            }
            .sheet(isPresented: $reconnecting) {
                NavigationStack { SignInFlow(prefilledEmail: app.needsReconnect, onDone: { reconnecting = false }) }
            }
        }
    }

    enum ShelfState: Equatable {
        case books
        /// The saved sign-in hasn't been read yet: plain paper for the blink it takes.
        case waiting
        /// Signed in, the Cloud hasn't answered yet, and nothing is cached.
        case dusting
        case empty(signedIn: Bool)
        case unreachable(LibraryStore.SyncProblem)
    }

    /// The empty state only once the Cloud has really said the shelf is empty (or there's no Cloud).
    private var shelfState: ShelfState {
        let library = app.library
        if !library.books.isEmpty { return .books }
        if !app.hasStarted { return app.accountInitial == nil ? .waiting : .dusting }
        guard app.account != nil else { return .empty(signedIn: false) }
        if library.isRefreshing || !library.hasRefreshed { return .dusting }
        if let problem = library.syncProblem { return .unreachable(problem) }
        return library.cloudIsEmpty ? .empty(signedIn: true) : .dusting
    }

    /// "Library", with Add and the account at the trailing edge, like Books' Home. On the cover
    /// screen the whole row moves down below the camera instead of squeezing the buttons inward.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Library")
                .font(.display(.largeTitle, weight: .bold))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                importing = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Add Books from Files")
            .accessibilityIdentifier("library.import")
            // A menu is hosted by UIKit and ignores the shelf's fade-in; it waits for the measured width too.
            if width > 0 { accountMenu } else { Color.clear.frame(width: 44, height: 44) }
        }
        .tint(Color.ink)
        .padding(.horizontal, metrics.gutter)
        .padding(.top, max(8, headerDrop))
        .padding(.bottom, 2)
    }

    /// The order covers drop in: Reading Now left to right, then the rest of the shelf.
    private var dropOrder: [String: Int] {
        var order: [String: Int] = [:]
        for book in app.library.readingNow + app.library.finishedBooks + app.library.allBooks where order[book.id] == nil {
            order[book.id] = order.count
        }
        return order
    }

    private func hidden(_ book: LibraryBook) -> Bool {
        guard let arrived else { return false }
        return (dropOrder[book.id] ?? 0) >= arrived
    }

    /// The shelf drops in once per launch, a cover at a time; the first shelf after sign-in says hello too.
    private func dropIn() {
        let library = app.library
        guard arrived == 0, !Self.hasDropped else { return }
        guard !library.books.isEmpty else { return }
        var text: String?
        if let account = app.account, !library.isRefreshing {
            let key = "arrived-\(account.email)"
            if !UserDefaults.standard.bool(forKey: key) || UserDefaults.standard.bool(forKey: "GatefoldReplayArrival") {
                UserDefaults.standard.set(true, forKey: key)
                let waiting = library.readingNow.first { $0.displayPercent > 0 }
                text = ArrivalGreeting.text(bookCount: library.books.count, waitingTitle: waiting?.title, waitingPercent: waiting?.displayPercent)
            }
        }
        Self.hasDropped = true
        let count = min(Self.arrivalCap, library.books.count)
        // A greeting gets the slow, one-by-one arrival; an ordinary launch is quicker.
        let step: Duration = text == nil ? .milliseconds(35) : .milliseconds(60)
        Task {
            if let text { withAnimation(.easeOut(duration: 0.4)) { greeting = text } }
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.35)) { arrived = .max }
            } else {
                for i in 0..<count {
                    withAnimation(.spring(duration: 0.45, bounce: 0.2)) { arrived = i + 1 }
                    if text != nil, i == 0 || i == count - 1 { arrivalTaps += 1 }
                    try? await Task.sleep(for: step)
                }
                // Past the first dozen, the rest of a big shelf settles in together.
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { arrived = .max }
            }
            try? await Task.sleep(for: .milliseconds(500))
            arrived = nil
            guard text != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeOut(duration: 0.6)) { greeting = nil }
        }
    }

    private var accountMenu: some View {
        Menu {
            if let account = app.account {
                Section(account.email) {
                    Text(account.store.name)
                    if app.needsReconnect != nil {
                        Button("Sign In Again", systemImage: "key") { reconnecting = true }
                    }
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmSignOut = true
                    }
                }
            } else {
                Button("Connect PocketBook Cloud", systemImage: "icloud") {
                    app.hasOnboarded = false
                }
            }
        } label: {
            // Until the saved sign-in is read, last launch's initial: the avatar never flips.
            AccountBadge(initial: app.hasStarted ? app.account?.email.first.map { String($0).uppercased() } : app.accountInitial,
                         needsAttention: app.needsReconnect != nil)
        }
        .accessibilityLabel(app.account.map { "Account, \($0.email)" } ?? "Account")
        .accessibilityIdentifier("library.account")
    }

    @ViewBuilder
    private var shelves: some View {
        let library = app.library
        let m = metrics
        VStack(alignment: .leading, spacing: 30) {
            let now = library.readingNow
            if !now.isEmpty {
                section("Reading Now") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .bottom, spacing: m.spacing + 8) {
                            ForEach(now) { book in
                                BookTile(book: book, shelf: .readingNow, width: m.large, namespace: namespace, onOpen: onOpen)
                                    .modifier(Drop(hidden: hidden(book)))
                            }
                        }
                        .padding(.horizontal, m.gutter)
                        .padding(.vertical, 10)
                        .scrollTargetLayout()
                    }
                    // Covers cast shadows; let them fall outside the row instead of being sliced off.
                    .scrollClipDisabled()
                    .modifier(SafeEdgeFade(active: trailingReserved))
                    .scrollTargetBehavior(.viewAligned)
                    .accessibilityIdentifier("library.readingNow")
                }
            }
            let finished = library.finishedBooks
            if !finished.isEmpty {
                section("Finished") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .bottom, spacing: m.spacing + 4) {
                            ForEach(finished) { book in
                                BookTile(book: book, shelf: .finished, width: m.grid, namespace: namespace, onOpen: onOpen)
                                    .modifier(Drop(hidden: hidden(book)))
                                    .transition(reduceMotion ? .opacity : .offset(y: -24).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, m.gutter)
                        .padding(.vertical, 10)
                    }
                    .scrollClipDisabled()
                    .modifier(SafeEdgeFade(active: trailingReserved))
                    .accessibilityIdentifier("library.finished")
                }
                .transition(.opacity)
            }
            section("All Books") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: m.grid), spacing: m.spacing, alignment: .bottomLeading)], spacing: m.spacing + 14) {
                    ForEach(library.allBooks) { book in
                        BookTile(book: book, shelf: .grid, width: nil, namespace: namespace, onOpen: onOpen)
                            .modifier(Drop(hidden: hidden(book)))
                    }
                }
                .padding(.horizontal, m.gutter)
                .accessibilityIdentifier("library.grid")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 28)
        // A book just finished drops onto the Finished shelf the way the shelf first arrived.
        .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.45, bounce: 0.2), value: library.finishedBooks.map(\.id))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.display(.title2, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, metrics.gutter)
                .padding(.bottom, -4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A cover on the shelf, with progress beneath it. No frame around it and nothing on it: the cover is
/// the object, and where the book is (Cloud, downloading) is said once, in the line beneath.
struct BookTile: View {
    enum Shelf { case readingNow, finished, grid }

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    let book: LibraryBook
    let shelf: Shelf
    /// A fixed cover width, or nil to fill the grid's column.
    let width: CGFloat?
    var namespace: Namespace.ID
    var onOpen: (LibraryBook) -> Void

    var body: some View {
        let state = app.library.state(of: book)
        Button {
            switch state {
            case .onDevice: onOpen(book)
            case .cloudOnly, .failed: Task { await app.library.download(book) }
            case .downloading: break
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // A 2:3 board whatever the artwork's own shape, so a row of covers lines up.
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { CoverView(book: book, image: app.library.cover(for: book), coverless: app.library.isCoverless(book)) }
                    .frame(width: width)
                    .frame(maxWidth: width == nil ? .infinity : nil)
                    .matchedTransitionSource(id: book.id, in: namespace)
                VStack(alignment: .leading, spacing: 3) {
                    if shelf == .readingNow {
                        Text(BookTitle.short(book.title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    }
                    footer(state)
                }
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .buttonStyle(PressScale())
        .contextMenu {
            if state == .onDevice {
                Button("Read", systemImage: "book") { onOpen(book) }
                Button("Remove from This \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")", systemImage: "trash", role: .destructive) {
                    app.library.remove(book)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title), \(book.author)")
        .accessibilityValue(accessibilityValue(state))
        .accessibilityHint(state == .onDevice ? "Opens the book" : "Downloads the book")
        .accessibilityIdentifier("book.\(book.id)")
    }

    /// Progress, then where the book is, in one quiet line.
    @ViewBuilder
    private func footer(_ state: DownloadState) -> some View {
        let p = book.displayProgression
        HStack(spacing: 6) {
            if book.isFinished {
                // On the Finished shelf the shelf's own title says it.
                if shelf != .finished { Text("Finished") }
            } else if p > 0.001 {
                // At the largest type sizes the number says it; the bar would squeeze it to "42…".
                if !typeSize.isAccessibilitySize {
                    ProgressView(value: p)
                        .tint(.ribbon)
                        .frame(maxWidth: 60)
                }
                Text("\(book.displayPercent)%").monospacedDigit()
            }
            switch state {
            case .cloudOnly:
                Image(systemName: "icloud.and.arrow.down")
                    .accessibilityHidden(true)
                if p <= 0.001, !book.isFinished { Text("In Cloud") }
            case .downloading:
                Image(systemName: "arrow.down.circle.dotted")
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
                if p <= 0.001, !book.isFinished { Text("Fetching…") }
            case .failed:
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Color.ribbon)
                    .accessibilityHidden(true)
                Text("Try again").foregroundStyle(Color.ribbon)
            case .onDevice:
                if p <= 0.001, !book.isFinished { Text(book.origin == .imported ? "Imported" : "New") }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private func accessibilityValue(_ state: DownloadState) -> String {
        var parts: [String] = []
        if book.isFinished { parts.append("finished") } else if book.displayProgression > 0.001 { parts.append("\(book.displayPercent) percent read") }
        switch state {
        case .cloudOnly: parts.append("in PocketBook Cloud")
        case .downloading: parts.append("downloading")
        case .failed: parts.append("download failed")
        case .onDevice: break
        }
        return parts.joined(separator: ", ")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// A cover with a soft page edge and spine highlight; a typeset cover when the book has none. A cover
/// still on its way shows as plain paper-coloured board, so a made-up cover never flashes before it.
struct CoverView: View {
    let book: LibraryBook
    let image: UIImage?
    var coverless = true

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else if coverless {
                GeneratedCover(title: BookTitle.display(book.title), author: book.author)
            } else {
                Color.ink.opacity(0.07)
            }
            // The spine: light catches the hinge of a real cover.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.16), location: 0.025),
                    .init(color: .clear, location: 0.06),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .animation(.easeOut(duration: 0.35), value: image == nil)
        .clipShape(.rect(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 6, topTrailingRadius: 6))
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 6)
    }
}

private struct GeneratedCover: View {
    let title: String
    let author: String

    var body: some View {
        let palette = [0x7A2E22, 0x2E4A5E, 0x3E5A34, 0x5B3A6B, 0x6B5326] as [UInt32]
        // A stable colour per title (String.hashValue changes every launch).
        let hue = palette[Int(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 9973 }) % palette.count]
        ZStack {
            Color(hex: hue)
            VStack(spacing: 10) {
                Rectangle().fill(.white.opacity(0.5)).frame(width: 30, height: 1)
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                Text(author.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .opacity(0.8)
                Rectangle().fill(.white.opacity(0.5)).frame(width: 30, height: 1)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }
}

/// The Cloud hasn't answered yet and nothing is cached: the shelf's outline, quietly breathing, and a
/// line that says what's happening. Never a spinner.
private struct DustingShelf: View {
    let metrics: ShelfMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var patient = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("The shelf is dusting itself off…")
                .font(.display(.title3, weight: .regular).italic())
                .foregroundStyle(Color.ink.opacity(0.8))
                .padding(.horizontal, metrics.gutter)
                .opacity(patient ? 1 : 0)
                .accessibilityIdentifier("library.dusting")
            HStack(alignment: .bottom, spacing: metrics.spacing + 8) {
                ForEach(0..<4, id: \.self) { i in ghost(i).frame(width: metrics.large, height: metrics.large * 1.5) }
            }
            .padding(.horizontal, metrics.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.grid), spacing: metrics.spacing)], spacing: metrics.spacing + 14) {
                ForEach(0..<6, id: \.self) { i in ghost(i + 4).aspectRatio(2 / 3, contentMode: .fit) }
            }
            .padding(.horizontal, metrics.gutter)
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fetching your books")
        .task {
            // A quick fetch shows only the outline; a slower one says what's going on.
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
            }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.4)) { patient = true }
        }
    }

    private func ghost(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.ink.opacity(breathe ? 0.09 : 0.05))
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(i) * 0.12), value: breathe)
    }
}

/// Signed out with nothing on the shelf, or the Cloud really did come back empty.
private struct EmptyShelf: View {
    let signedIn: Bool
    var onImport: () -> Void
    var onConnect: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.ribbon)
                .symbolEffect(.wiggle, options: .nonRepeating)
            Text(signedIn ? "Room on the Shelf" : "A Shelf with Room to Spare")
                .font(.display(.title2, weight: .bold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("library.empty")
            Text(signedIn
                 ? "Books you add to PocketBook Cloud will land here. EPUBs from Files are welcome too."
                 : "Slip in an EPUB from Files, or connect PocketBook Cloud to bring your InkPad's books along.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onImport) {
                Label("Add Books from Files", systemImage: "folder").foregroundStyle(Color.onRibbon)
            }
            .buttonStyle(.glassProminent)
            .tint(.ribbon)
            .controlSize(.large)
            if !signedIn {
                Button("Connect PocketBook Cloud", action: onConnect)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Signed in, nothing cached, and the Cloud can't be reached: say so plainly, with a way to try again.
private struct UnreachableShelf: View {
    let problem: LibraryStore.SyncProblem
    var onRetry: () -> Void
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: problem == .offline ? "wifi.slash" : "exclamationmark.icloud")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.ribbon)
            Text("Can't Reach Your Shelf")
                .font(.display(.title2, weight: .bold))
                .foregroundStyle(Color.ink)
                .accessibilityIdentifier("library.unreachable")
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise").foregroundStyle(Color.onRibbon)
            }
            .buttonStyle(.glassProminent)
            .tint(.ribbon)
            .controlSize(.large)
            Button("Add Books from Files", action: onImport)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.ink)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var detail: String {
        switch problem {
        case .offline: "You're offline. The moment you're back, your InkPad's books will hop onto this shelf."
        case .signInExpired: "PocketBook Cloud would like you to sign in again."
        case let .other(message): message
        }
    }
}

/// The account button: the reader's initial on the ribbon colour, a plain silhouette when signed out,
/// and a small dot when the Cloud wants them to sign in again.
private struct AccountBadge: View {
    let initial: String?
    let needsAttention: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let initial {
                Text(initial)
                    .font(.system(.headline, design: .serif, weight: .bold))
                    .foregroundStyle(Color.onRibbon)
                    .frame(width: 36, height: 36)
                    .background(Color.ribbon.gradient, in: .circle)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.ink)
            }
            if needsAttention {
                Circle().fill(.orange).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.paper, lineWidth: 2))
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(.circle)
    }
}

/// One quiet line under the title about the Cloud: checking, up to date (and how long ago), offline,
/// or asking to sign in again. Nothing when there's no Cloud account.
private struct SyncStatusLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reconnecting = false

    private var health: SyncHealth? {
        let library = app.library
        guard app.account != nil || (!app.hasStarted && app.accountInitial != nil) else { return nil }
        if library.isRefreshing || !app.hasStarted { return .checking }
        if library.syncProblem == .offline { return .offline(lastSynced: library.lastSynced) }
        if let last = library.lastSynced, library.syncProblem == nil { return .upToDate(last) }
        return nil
    }

    var body: some View {
        Group {
            if let email = app.needsReconnect {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.orange)
                    Text("PocketBook Cloud would like you to sign in again.")
                        .foregroundStyle(.secondary)
                    Button("Sign In") { reconnecting = true }
                        .fontWeight(.semibold)
                        .tint(.ribbon)
                        .accessibilityIdentifier("library.reconnect")
                }
                .sheet(isPresented: $reconnecting) {
                    NavigationStack { SignInFlow(prefilledEmail: email, onDone: { reconnecting = false }) }
                }
            } else if case let .other(message)? = app.library.syncProblem, app.account != nil {
                Label(message, systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.secondary)
            } else if let health {
                // Relative times tick over on their own ("just now" becomes "1 min ago").
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Label {
                        Text(health.text(now: context.date))
                            .contentTransition(.opacity)
                    } icon: {
                        icon(health)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(health.text(now: context.date))
                    .accessibilityIdentifier("library.syncHealth")
                }
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: 0.3), value: health)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.syncStatus")
    }

    @ViewBuilder
    private func icon(_ health: SyncHealth) -> some View {
        switch health {
        case .checking:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
        case .upToDate:
            Image(systemName: "checkmark.circle").foregroundStyle(Color.ribbon)
        case .offline:
            Image(systemName: "wifi.slash")
        }
    }
}

/// Where the system reserves the trailing edge (the cover screen's camera and status column), a
/// sideways shelf stops at the safe area with a soft fade instead of running under the clock.
private struct SafeEdgeFade: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
                // Shadows still fall above and below the row.
                .padding(.vertical, -24)
                .padding(.leading, -40)
            }
        } else {
            content
        }
    }
}

/// A cover not yet on the shelf: just above its place, transparent. Dropping it in springs it down.
private struct Drop: ViewModifier {
    let hidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: hidden && !reduceMotion ? -24 : 0)
            .opacity(hidden ? 0 : 1)
    }
}
