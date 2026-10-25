// iPhone Duo's inner display (regular width in every pose, tech talk 111461 "Prepare your app for iPhone Duo"): a
// page's list keeps one centred column of a readable width instead of stretching its rows across the whole display.
// On the unfolded Duo, Apple's own pages that are a list of rows or fields do the same: Shortcuts' editor and Wallet
// keep one column in the middle, Health opens Profile's rows in a centred sheet (Duo simulator screenshots, 10-25).
// HIG Layout: "The system includes predefined layout guides that make it easy to apply standard margins around content
// and restrict the width of text for optimal readability." SwiftUI has no readable-width guide (UIKit's readableContentGuide).
// The grouped background still runs edge to edge; the outer display (compact width) and Android are unchanged.

import SwiftUI

extension View {
    /// The list as one centred column on a regular-width display (see the file comment).
    func readableColumn() -> some View {
        #if os(Android)
        self
        #else
        modifier(ReadableColumn())
        #endif
    }
}

#if !os(Android)
private struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var space = Space()
    /// The column with the list's own side margins: UIKit's readable content width (672 pt at the default text size)
    /// for the rows. It grows with the text size as the system's readable guide does (HIG Designing for iPhone Duo:
    /// "Avoid fixed widths"); at the largest sizes the list takes the whole width again.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 712

    /// The list's own width, and where the fold starts while a vertical fold (the book pose) divides it.
    private struct Space: Equatable {
        var width: CGFloat = 0
        var foldStart: CGFloat?
    }

    func body(content: Content) -> some View {
        // measured outside the padding: the padding narrows the safe area the list sees, not this frame
        content
            .safeAreaPadding(.leading, leading)
            .safeAreaPadding(.trailing, trailing)
            .onGeometryChange(for: Space.self) { proxy in
                // a page that is one list (the pushed pages; the tab pages split in DuoColumns): folded like a book, the
                // list keeps to the half before the fold instead of running every row across it. HIG Designing for
                // iPhone Duo: "Use the ReservedRegion API to keep important elements clear of the center if the system
                // doesn't move them automatically."
                #if os(iOS)
                let fold = proxy.reservedRegions(kind: .division).first { $0.isActive && $0.frame.height > $0.frame.width }
                return Space(width: proxy.size.width, foldStart: fold?.frame.minX)
                #else
                return Space(width: proxy.size.width)   // macOS (the unit tests' build): no ReservedRegion before 27.1
                #endif
            } action: { space = $0 }
    }

    private var centred: CGFloat { sizeClass == .regular ? max(0, (space.width - column) / 2) : 0 }
    private var leading: CGFloat { space.foldStart == nil ? centred : 0 }
    /// folded: as far from the fold as the cards are from the screen's edge (the list adds no margin of its own at a
    /// padded edge, so its cards ran up to the fold)
    private var trailing: CGFloat { space.foldStart.map { max(0, space.width - $0) + 20 } ?? centred }
}
#endif
