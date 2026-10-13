import SwiftUI

/// There is no toast layer any more (Pages/Shell/Feedback.swift says where each kind of message went). Kept only so a
/// page that still overlays it builds until its owner takes the line out; it draws nothing.
@available(*, deprecated, message: "no toasts: remove the overlay (Pages/Shell/Feedback.swift)")
struct ToastLayer: View {
    var body: some View {
        EmptyView()
    }
}
