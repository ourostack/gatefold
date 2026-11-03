import Observation
import SwiftUI

/// The state of one page turn drawn over the navigator: the page that lifts, the page beneath and
/// where the corner is. The host drives `finger`; SwiftUI animates it to complete or cancel.
@MainActor @Observable
final class CurlModel {
    enum Style { case curl, fade }

    var isActive = false
    var style: Style = .curl
    /// The page as it was when the turn began.
    var top: UIImage?
    /// The destination page; nil while it's still rendering underneath.
    var beneath: UIImage?
    /// True when turning backward: everything is mirrored so the leaf lifts from the left edge.
    var mirrored = false
    var size: CGSize = .zero
    /// A two-page spread turns only its outer leaf.
    var isSpread = false
    var corner: CGPoint = .zero
    var finger: CGPoint = .zero
    var fade: Double = 0
    var paper: Color = .white
    var ink: Color = .black
    var isDark = false
    /// A leaf lifted on the reopen picture, waiting for the live page: it breathes until it lands.
    var holding = false

    /// The finger position that leaves the leaf fully turned. A single page's leaf leaves the screen,
    /// past the roll. A spread's leaf lands on the other page: its corner on that page's outer
    /// corner, exactly, where the leaf's back lies over the page beneath with no offset. (Build 14
    /// overshot by the roll's length, so the landed leaf sat about 55 pt toward the outer edge with
    /// the old page showing beside it, and jumped back when the overlay lifted.)
    var turnedFinger: CGPoint {
        isSpread ? CGPoint(x: spreadLanding, y: corner.y) : CGPoint(x: -size.width - .pi * baseRadius - 8, y: corner.y)
    }

    /// Where a spread's corner lands, in the leaf's own (unmirrored) space: the spine reflected.
    var spreadLanding: CGFloat { 2 * (size.width / 2) - size.width }

    private var baseRadius: CGFloat {
        let leafWidth = isSpread ? size.width / 2 : size.width
        return max(18, leafWidth * 0.075)
    }

    /// The roll's radius. A spread's leaf flattens over the last stretch of its travel, so it lies
    /// flat on the page as it lands, the way a sheet settles, and nothing changes when the overlay lifts.
    var radius: CGFloat {
        guard isSpread else { return baseRadius }
        let leafFinger = mirrored ? size.width - finger.x : finger.x
        let travel = (leafFinger - spreadLanding) / max(1, size.width / 2 * 0.3)
        return max(0.5, baseRadius * min(1, max(0, travel)))
    }

    func reset() {
        isActive = false
        holding = false
        top = nil
        beneath = nil
        fade = 0
    }
}

struct CurlOverlay: View {
    let model: CurlModel

    var body: some View {
        if model.isActive, let top = model.top {
            let size = model.size
            ZStack(alignment: .topLeading) {
                model.paper
                if let beneath = model.beneath {
                    page(beneath)
                }
                switch model.style {
                case .fade:
                    page(top).opacity(1 - model.fade)
                case .curl:
                    curl(top: top, beneath: model.beneath, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func page(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: model.size.width, height: model.size.height)
    }

    @ViewBuilder
    private func curl(top: UIImage, beneath: UIImage?, size: CGSize) -> some View {
        let mirror: CGFloat = model.mirrored ? -1 : 1
        let leafMinX = model.isSpread ? size.width / 2 : 0
        // In mirrored (backward) space the leaf is the left page, drawn as if it were the right one.
        let corner = model.mirrored ? CGPoint(x: size.width - model.corner.x, y: model.corner.y) : model.corner
        let raw = model.mirrored ? CGPoint(x: size.width - model.finger.x, y: model.finger.y) : model.finger
        // A spread's leaf never goes past its landing: dragged further, it lies where it lands.
        let finger = model.isSpread ? CGPoint(x: max(raw.x, model.spreadLanding), y: raw.y) : raw
        // The leaf's back in a spread shows the destination page, passed to the shader as an image
        // (laying it beside the page in a double-width layer drew everything shifted).
        let back = Image(uiImage: beneath ?? top)
        page(top)
            .scaleEffect(x: mirror, y: 1)
            .layerEffect(
                ShaderLibrary.pageCurl(
                    .float(size.width),
                    .float4(leafMinX, 0, size.width, size.height),
                    .float2(corner),
                    .float2(finger),
                    .float(model.radius),
                    .color(model.paper),
                    .color(model.ink),
                    .float(model.isSpread && beneath != nil ? 1 : 0),
                    .float(model.isDark ? 1 : 0),
                    .image(back),
                    .float(model.mirrored ? 1 : 0)
                ),
                maxSampleOffset: CGSize(width: size.width, height: size.height)
            )
            .frame(width: size.width, height: size.height)
            .clipped()
            .scaleEffect(x: mirror, y: 1)
    }
}
