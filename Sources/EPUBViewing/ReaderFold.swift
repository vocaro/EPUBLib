import SwiftUI

/// The fold `EPUBReaderView` finds for itself: the `.division` reserved region that iPhone Duo
/// reports for its fold from iOS 27.1. The reader uses it as it uses a frame a host gives to
/// `View.epubReaderDivision(_:)`, and a frame the host gives wins (doc/native-viewer.md, "Book
/// pose").
enum ReaderFold {
    /// A reserved region as the system reports it, in the reader view's coordinates: its frame
    /// includes the margins the system keeps around the fold.
    struct Region: Equatable, Sendable {
        var frame: CGRect
        var isActive: Bool
    }

    /// The division the reader keeps text off: the host's frame when it gives one, else the fold
    /// the reader found.
    static func division(host: CGRect?, found: CGRect?) -> CGRect? { host ?? found }

    /// The vertical fold among `regions`, active or not. The system reports the fold as active
    /// while the phone is partly folded and as inactive while it lies flat; both put the gutter
    /// on it, so folding the phone changes nothing on the page. An active region comes before an
    /// inactive one. A horizontal region, as the inner display upright or in the laptop pose
    /// has, reserves nothing, as a horizontal frame from the host does.
    static func found(in regions: [Region]) -> CGRect? {
        let vertical = regions.filter { !$0.frame.isNull && $0.frame.height > $0.frame.width }
        return (vertical.first(where: \.isActive) ?? vertical.first)?.frame
    }
}

extension EnvironmentValues {
    /// Regions for `EPUBReaderView` to find the fold in, in place of the system's. Tests give
    /// them; nil, the default, reads the system's.
    @Entry var epubReaderFoldRegions: [ReaderFold.Region]? = nil
}

/// Reads the `.division` reserved regions of the view it modifies into `found`.
struct ReaderFoldReader: ViewModifier {
    @Binding var found: CGRect?
    @Environment(\.epubReaderFoldRegions) private var given

    /// One structure whatever the regions, so that the reader inside is never mounted again.
    func body(content: Content) -> some View {
        system(content)
            .onChange(of: given, initial: true) { if let given { found = ReaderFold.found(in: given) } }
    }

    /// The regions are in the view's own coordinates, unmirrored, as the canvas lays out in a
    /// right-to-left environment too. The macOS 27.0 SDK has no reserved regions, and a Mac no
    /// fold.
    @ViewBuilder private func system(_ content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content.onGeometryChange(for: CGRect?.self) { proxy in
                ReaderFold.found(in: proxy.reservedRegions(kind: .division, options: .includeInactive,
                                                           layoutDirectionBehavior: .fixed)
                    .map { ReaderFold.Region(frame: $0.frame, isActive: $0.isActive) })
            } action: { if given == nil { found = $0 } }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
