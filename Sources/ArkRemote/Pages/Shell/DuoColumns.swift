// iPhone Duo's inner display held wider than tall: a page's sections in two columns, side by side in the system's
// ArrangementView, which divides them at the hinge when the device folds. HIG Designing for iPhone Duo: "A split
// arrangement divides its area between its primary and secondary views. It splits horizontally when the arrangement is
// wider than it is tall"; "Adapt your layout when the device folds. Prefer a layout container that adapts
// automatically"; "Avoid extreme layout changes as people fold the device" — the columns stay the same open and folded,
// folding only narrows them. One list in one centred column ran every row across the fold (its label on one half, its
// value on the other), and ReservedRegion's division is "an area where content splits into separate regions, such as at
// the fold of a hinge. Arrange your content into separate sections on each side of this area."
//
// Taller than wide (portrait), the arrangement would stack two scrolling halves and cut the first at the boundary, and
// `.split.axes(.horizontal)` drops the second half altogether (Duo simulator 27.1, 10-25), so portrait, the outer
// display and Split View keep the one list (ReadableColumn.swift). iOS only: Android pages keep their own single List,
// whose sections skip-ui finds by type (MonthCardRows.swift).

import SwiftUI

#if !os(Android)
struct DuoColumns<First: View, Second: View>: View {
    /// A Form instead of a List for both columns (方舟 is a Form).
    var form = false
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var space = Space()

    /// Whether the page's own space is wider than tall, and whether the fold divides it right now.
    private struct Space: Equatable {
        var wider = false
        var folded = false
    }

    var body: some View {
        Group {
            if sizeClass == .regular && space.wider {
                // the arrangement leaves its panes about 2 pt each side of the split: open, the cards of the two
                // columns nearly touched, so a 20 pt gutter; folded, as far from the fold as from the screen's edge
                ArrangementView {
                    column { first }
                        .safeAreaPadding(.trailing, gutter)
                } secondary: {
                    column { second }
                        .safeAreaPadding(.leading, gutter)
                }
            } else {
                column {
                    first
                    second
                }
                .readableColumn()
            }
        }
        .onGeometryChange(for: Space.self) { proxy in
            Space(wider: proxy.size.width > proxy.size.height,
                  folded: proxy.reservedRegions(kind: .division).contains { $0.isActive })
        } action: { space = $0 }
    }

    private var gutter: CGFloat { space.folded ? 18 : 8 }

    @ViewBuilder private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if form {
            Form { content() }
        } else {
            List { content() }
        }
    }
}
#endif
