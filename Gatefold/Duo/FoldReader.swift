import GatefoldCore
import SwiftUI

/// Reads the fold (iOS 27.1 reserved regions) and the hinge for the reader's layout.
/// Layout comes from the division region; the hinge angle only drives the spine shadow.
enum FoldReader {
    static func division(in proxy: GeometryProxy) -> FoldRegion? {
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            guard let region = regions.first else { return nil }
            return FoldRegion(frame: region.frame, isActive: region.isActive)
        }
        return nil
    }

    /// What the system says is covered (the folded Duo's cover-screen camera and status column).
    static func occlusions(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion, options: .includeInactive).map(\.frame)
        }
        return []
    }
}

private struct HingeObserver: ViewModifier {
    @Binding var hinge: HingeState

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                guard let h = new.hinge else {
                    hinge = .none
                    return
                }
                switch h.status {
                case .closed: hinge = .closed
                case .fullyOpen: hinge = .fullyOpen
                default: hinge = .partiallyOpen(angleDegrees: h.angle.degrees)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func observingHinge(_ hinge: Binding<HingeState>) -> some View {
        modifier(HingeObserver(hinge: hinge))
    }
}
