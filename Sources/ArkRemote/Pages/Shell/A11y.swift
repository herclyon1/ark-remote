import SwiftUI

/// A warning line: ⚠ and the text. The text says it all, so the triangle is hidden from screen readers (HIG VoiceOver:
/// "Exclude purely decorative images from VoiceOver."). `Label(_:systemImage:)` would not do: on Android skip-ui draws
/// the symbol as a Material Icon whose content description is the symbol name (skip-ui 1.61.0 Image.swift:495), and
/// a screen reader got that English name.
func warningLabel(_ text: String) -> some View {
    Label {
        Text(verbatim: text)
    } icon: {
        Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
    }
}

/// A picture from the asset catalog that the text beside it already names: hidden from screen readers (HIG VoiceOver,
/// as above). iOS: `Image(decorative:bundle:)` ("SwiftUI ignores this image for accessibility purposes."). skip-fuse-ui
/// marks that initializer unavailable (SkipSwiftUI Image.swift:154), and skip-ui draws a named image on Android with no
/// content description at all (skip-ui Image.swift:433-441), so the plain initializer is the same thing there.
func decorativeImage(_ name: String) -> Image {
    #if os(Android)
    Image(name, bundle: assetBundle)
    #else
    Image(decorative: name, bundle: assetBundle)
    #endif
}
