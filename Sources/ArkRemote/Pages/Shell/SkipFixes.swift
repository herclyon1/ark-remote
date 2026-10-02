import SwiftUI

// Three places where the same SwiftUI code draws differently through Skip on Android, with the way around each.
// scripts/check-android-symbols.py guards the symbol names.

/// The bundle for `Image("name", bundle: assetBundle)` (Resources/Module.xcassets).
///
/// On Android, SwiftPM's generated `Bundle.module` (resource_bundle_accessor.swift) tries
/// `Bundle(url: Bundle.main.resourceURL + "ark-remote_ArkRemote.bundle")` first, and skip-android-bridge's
/// `AndroidBundle.init?(url:)` accepts any URL, so the module bundle points at an asset folder the APK does not
/// have. SkipUI then finds no `<name>.imageset` and draws nothing: every named image was blank. With no bundle
/// SkipUI uses skip.foundation's `Bundle.main`, which is this module's asset folder (assets/ark/remote/Resources).
#if os(Android)
let assetBundle: Bundle? = nil
#else
let assetBundle: Bundle? = .module
#endif

/// An SF Symbol on iOS; on Android the Material icon named `android` (skip-ui Image.swift composeImageVector
/// takes "Icons.Outlined.X" names directly). For symbols outside skip-ui's table, which it draws as a warning triangle.
func symbol(_ ios: String, android: String) -> Image {
    #if os(Android)
    Image(systemName: android)
    #else
    Image(systemName: ios)
    #endif
}

/// The row background for `.listRowBackground`, never nil on Android: skip-ui composes a row with a background inside an
/// extra layout and one without it directly (List.swift:692-722), so a row whose tint comes and goes (「待保存」 on the first
/// keystroke) is rebuilt and its text field loses the keyboard. With no tint the row gets the colour skip-ui would have
/// drawn itself (Color(.systemBackground) = MaterialTheme surface, List.swift:693 / Color.swift:202-207).
func rowBackground(_ tint: Color?) -> Color? {
    #if os(Android)
    tint ?? Color(.systemBackground)
    #else
    tint
    #endif
}

/// `if shown { Section … }` for the top level of a List.
///
/// A false `if` reaches SkipUI as an EmptyView, and its List takes that for a row: an item after a section footer
/// opens a section of its own (skip-ui LazySupport.swift, LazyItemCollector `item`), so an empty grey section gap
/// is drawn. A ForEach over no elements adds nothing (skip-ui ForEach.swift Evaluate), and over one it unrolls
/// to the Section as written. `id` becomes the section's identity, so it must differ between the sections of one
/// List (skip-ui List keys the section chrome by it; two equal ids crash the LazyColumn).
func listSection<Content: View>(_ id: String, if shown: Bool, @ViewBuilder _ content: @escaping () -> Content) -> some View {
    ForEach(shown ? [id] : [], id: \.self) { _ in content() }
}

/// `if let value { Section … }` for the top level of a List; see `listSection(_:if:)`.
func listSection<Value, Content: View>(_ id: String, ifLet value: Value?, @ViewBuilder _ content: @escaping (Value) -> Content) -> some View {
    ForEach(value == nil ? [] : [id], id: \.self) { _ in
        if let value { content(value) }
    }
}
