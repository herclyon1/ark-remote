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
    @State private var width: CGFloat = 0
    /// The column with the list's own side margins: UIKit's readable content width (672 pt at the default text size)
    /// for the rows. It grows with the text size as the system's readable guide does (HIG Designing for iPhone Duo:
    /// "Avoid fixed widths"); at the largest sizes the list takes the whole width again.
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 712

    func body(content: Content) -> some View {
        // measured outside the padding: the padding narrows the safe area the list sees, not this frame
        content
            .safeAreaPadding(.horizontal, sizeClass == .regular ? max(0, (width - column) / 2) : 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}
#endif
