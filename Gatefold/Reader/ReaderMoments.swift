import GatefoldCore
import SwiftUI

/// A slip of paper that slides out of the top of the page: the sync landed ("From your InkPad ·
/// 2 h ago"), or the other device is further on, with its passage and Jump or Stay.
struct SyncSlipView: View {
    let slip: SyncSlip
    let kind: ReaderModel.SlipKind
    let theme: ReaderTheme
    var onJump: () -> Void
    var onStay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    @State private var faded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(slip.title)
                        .font(.display(.subheadline))
                        .fixedSize(horizontal: false, vertical: true)
                        // The ribbon underline draws itself in, then fades: the same stroke as on the page.
                        .overlay(alignment: .bottomLeading) {
                            Capsule()
                                .fill(theme.accent)
                                .frame(height: 2)
                                .scaleEffect(x: drawn ? 1 : 0, anchor: .leading)
                                .opacity(faded ? 0 : 1)
                                .offset(y: 4)
                                .accessibilityHidden(true)
                        }
                    if let detail = slip.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(theme.text.opacity(0.8))
                            .padding(.top, 2)
                    }
                }
            }
            if let passage = slip.passage {
                Text(PassageQuote.quoted(passage))
                    .font(.system(.footnote, design: .serif).italic())
                    .foregroundStyle(theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            if kind == .ahead {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(action: onStay) {
                        Text("Carry on here")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minWidth: 64, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text)
                    .accessibilityLabel("Carry On Here")
                    .accessibilityIdentifier("banner.dismiss")
                    Button(action: onJump) {
                        Text("Catch up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.onAccent)
                            .padding(.horizontal, 18)
                            .frame(minWidth: 72, minHeight: 44)
                            .background(theme.accent, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("banner.jump")
                }
            }
        }
        .foregroundStyle(theme.text)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, kind == .ahead ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque paper, a shade off the page, with the soft shadow of a slip tucked into a book.
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 4)
                .fill(theme.background.mix(with: theme.text, by: theme.palette.isDark ? 0.10 : 0.045))
                .shadow(color: .black.opacity(theme.palette.isDark ? 0.5 : 0.14), radius: 10, y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(kind == .ahead ? "banner" : "slip")
        .accessibilityLabel(slip.title)
        .onAppear {
            AccessibilityNotification.Announcement(slip.title).post()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.6).delay(0.25)) { drawn = true }
            withAnimation(.easeIn(duration: 2).delay(0.85)) { faded = true }
        }
    }
}

/// The last leaf: the cover with its silk ribbon hanging out below, "The End", and a line about the
/// read itself (where it began, where it finished).
struct EndLeafView: View {
    let model: ReaderModel
    let leaf: ReaderModel.EndLeaf
    var onLibrary: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    /// A regular-by-regular page: the iPad, or an unfolded spread.
    private var tall: Bool { widthClass == .regular && heightClass == .regular }

    /// "Started on your InkPad, finished here on your phone" over "Read over 12 days", from what the shelf knows.
    private var story: String {
        guard let book = app.library.book(model.bookID) else { return leaf.line }
        return ReadStory.text(
            otherDevice: book.otherDevice,
            otherSince: book.otherSince,
            started: book.started,
            finished: book.finished ?? Date(),
            sessions: book.sessions ?? 1,
            here: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone"
        )
    }

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack(alignment: .top) {
                // The ribbon is tucked in at the last page and falls out below the book, beside its
                // title rather than across it, like the bookmark of a cloth-bound book.
                SilkRibbon(color: theme.accent, dark: theme.palette.isDark)
                    // Out of the book's foot: it slips down from under the cover's bottom edge and sways to rest.
                    .frame(width: 11, height: settled || reduceMotion ? 76 : 12, alignment: .top)
                    .rotationEffect(.degrees(settled ? 3 : (reduceMotion ? 3 : -6)), anchor: .top)
                    .offset(x: 36, y: 168)
                    .opacity(settled || !reduceMotion ? 1 : 0)
                    .accessibilityHidden(true)
                cover
                    .frame(width: 120, height: 180)
            }
            .frame(height: 252, alignment: .top)
            .padding(.bottom, 14)
            Text("The End")
                .font(.system(size: 40, weight: .regular, design: .serif).italic())
                .accessibilityAddTraits(.isHeader)
            // The story and its span, a line each (`ReadStory.text`), rather than wherever the width breaks.
            Text(story)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(theme.text.opacity(0.8))
                .padding(.top, 10)
                .padding(.horizontal, 28)
                .accessibilityIdentifier("endLeaf.line")
            // A tall page (the iPad) keeps the buttons near the words, the whole leaf sitting a little
            // above the middle, instead of a wide band of bare paper between them; the phone's page is
            // short enough that the buttons rest at its foot.
            Spacer(minLength: 28)
                .frame(maxHeight: tall ? 64 : .infinity)
            VStack(spacing: 12) {
                Button(action: onLibrary) {
                    Text("Back to Library")
                        .font(.headline)
                        .foregroundStyle(theme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(theme.accent, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("endLeaf.library")
                if leaf.cloud {
                    Button {
                        Task { await model.markFinishedOnCloud() }
                    } label: {
                        Label(leaf.markedOnCloud ? "Finished on Your InkPad" : "Mark Finished on InkPad",
                              systemImage: leaf.markedOnCloud ? "checkmark" : "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass(.regular.tint(theme.background.opacity(0.7))))
                    .disabled(leaf.markedOnCloud)
                    .accessibilityIdentifier("endLeaf.markFinished")
                }
                Button("Back to the Last Page") { model.leaveEndLeaf() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("endLeaf.back")
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
            if tall {
                // The rest of the paper is shared above and below the leaf.
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(theme.text)
        .tint(theme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endLeaf")
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 1.2, bounce: 0.3).delay(0.35)) { settled = true }
        }
    }

    @ViewBuilder private var cover: some View {
        if let image = model.cover {
            Image(uiImage: image).resizable().scaledToFill()
                .clipShape(.rect(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 5, topTrailingRadius: 5))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
        } else {
            VStack(spacing: 8) {
                Rectangle().fill(model.theme.text.opacity(0.4)).frame(width: 24, height: 1)
                Text(model.title).font(.system(.headline, design: .serif)).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                Rectangle().fill(model.theme.text.opacity(0.4)).frame(width: 24, height: 1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.background.mix(with: model.theme.text, by: 0.08), in: .rect(cornerRadius: 4))
        }
    }
}

/// A narrow ribbon of silk: soft shading across its width (the weave catches light down the middle),
/// a slight sheen, and a notched swallowtail end.
private struct SilkRibbon: View {
    let color: Color
    let dark: Bool

    var body: some View {
        SwallowtailShape()
            .fill(color)
            .overlay {
                SwallowtailShape().fill(LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.28), location: 0),
                        .init(color: .white.opacity(dark ? 0.10 : 0.22), location: 0.42),
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.32), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                ))
            }
            .overlay {
                // Where it leaves the book it's in the cover's shadow.
                SwallowtailShape().fill(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.16)))
            }
            .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 1.5, x: 1, y: 1.5)
    }
}

/// A strip with a V cut into its end.
private struct SwallowtailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let notch = rect.width * 0.85
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notch))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// While the first page lays out: the page colour and the book's cover, never a spinner. After
/// 1.5 s a hairline of ribbon creeps along the top so a slow open still says something is happening.
struct OpeningPlaceholder: View {
    let model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slow = false
    @State private var progress = 0.0

    var body: some View {
        ZStack(alignment: .top) {
            model.theme.background
            if let cover = model.cover {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 6, topTrailingRadius: 6))
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
                    // Every open is the same move: the cover grows to fill the page, as a book's
                    // cover fills your hands, and the first page takes its place.
                    .padding(.horizontal, 28)
                    .padding(.vertical, 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if slow {
                GeometryReader { geo in
                    Capsule()
                        .fill(model.theme.accent)
                        .frame(width: reduceMotion ? geo.size.width : max(8, geo.size.width * progress), height: 2)
                        .opacity(reduceMotion ? 0.6 : 1)
                }
                .frame(height: 2)
                .transition(.opacity)
                .accessibilityLabel("Opening")
            }
        }
        .accessibilityIdentifier("reader.opening")
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.3)) { slow = true }
            withAnimation(.easeOut(duration: 8)) { progress = 0.9 }
            // A first page that never reports in still shows rather than hiding behind the cover.
            try? await Task.sleep(for: .seconds(10))
            model.forceReady()
        }
    }
}

/// The unfold: a leaf of paper swings open from the spine over the right page while it lays out,
/// then gives way to it. Folding plays it backward.
struct UnfoldLeaf: View {
    let theme: ReaderTheme
    /// Degrees about the leading edge; 0 is flat open.
    var angle: Double
    var opacity: Double

    var body: some View {
        LinearGradient(
            colors: [theme.background.mix(with: .black, by: theme.palette.isDark ? 0.25 : 0.10), theme.background],
            startPoint: .leading,
            endPoint: UnitPoint(x: 0.25, y: 0.5)
        )
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.6)
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The "read on without you" slip, folded into a tab hanging in the page's top margin.
struct AheadTab: View {
    let label: String
    let theme: ReaderTheme
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Image(systemName: "book.pages")
                    .font(.caption2.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(theme.accent, in: UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 8, bottomTrailing: 8, topTrailing: 0)))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .frame(minWidth: 44, minHeight: 44, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Your InkPad read on. Show the offer")
        .accessibilityIdentifier("banner.tab")
    }
}
