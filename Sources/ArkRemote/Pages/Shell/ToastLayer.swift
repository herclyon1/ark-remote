import SwiftUI

/// view.js toast(t, ms): one line in the middle of the screen over every tab (index.html .toast: left/top 50%, the
/// UIAccessibilityHUDView position), gone after `ms`. Relay.toast holds the message; this layer clears it when its time is up.
struct ToastLayer: View {
    var body: some View {
        let t = Relay.shared.toast
        ZStack {
            if let t {
                Text(t.text)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 32)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.1), value: t?.at)
        // view.js: clearTimeout(toast._t); toast._t = setTimeout(hide, ms) — a newer toast restarts the wait
        .task(id: t?.at) {
            guard let t else { return }
            let left = Double(t.ms) - (nowMs() - t.at)
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000)) }
            if !Task.isCancelled, Relay.shared.toast?.at == t.at { Relay.shared.toast = nil }
        }
    }
}
