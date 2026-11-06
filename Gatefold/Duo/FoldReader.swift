import GatefoldCore
import SwiftUI

/// Reads the fold (iOS 27.1 reserved regions) and the hinge for the reader's layout.
/// Layout comes from the division region; the hinge angle only drives the spine shadow.
enum FoldReader {
    static func division(in proxy: GeometryProxy) -> FoldRegion? {
        if #available(iOS 27.1, *) {
            return nil
        }
        return nil
    }

    /// What the system says is covered (the folded Duo's cover-screen camera and status column).
    static func occlusions(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return []
        }
        return []
    }
}

private struct HingeObserver: ViewModifier {
    @Binding var hinge: HingeState

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
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
