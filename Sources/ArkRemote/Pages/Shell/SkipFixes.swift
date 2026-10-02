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

extension View {
    /// Text fields under this view lose focus, as a web input blurs, when the user taps outside them or hides the keyboard
    /// with the system back gesture. No-op on iOS.
    ///
    /// On Android neither takes the focus away: a tap on a plain row or blank list space lands on no focusable control,
    /// and back with the keyboard up only hides the keyboard (the Compose field keeps focus). Setting the `@FocusState`
    /// to false from SwiftUI does not help: skip-ui's `focused` only ever requests Compose focus (System/Focus.swift:13-31)
    /// and never clears it, so the field kept its keyboard and later edits went unchecked. So this clears the Compose
    /// focus itself (skip-ui README "composeModifier", Skip Fuse: a ContentModifier from a `#if SKIP` block), which ends
    /// in the field's `onFocusChanged` and so in its `@FocusState` going false. Taps that a control consumes (a button, a
    /// switch, the field itself) do not reach this; IME Done already clears focus (skip-ui TextField.swift:88, 470-487).
    func clearsFocusOnOutsideTap() -> some View {
        #if os(Android)
        composeModifier { ClearFocusOutsideFields() }
        #else
        self
        #endif
    }
}

#if SKIP
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import kotlinx.coroutines.flow.distinctUntilChanged

/// See `clearsFocusOnOutsideTap()`. `composed` because composeModifier's block is not composable
/// (skip-ui ComposeView.swift:55) and the focus manager and IME insets are read from the composition.
struct ClearFocusOutsideFields: ContentModifier {
    func modify(view: any View) -> any View {
        view.composeModifier { modifier in
            modifier.composed {
                let focusManager = LocalFocusManager.current
                let ime = WindowInsets.ime
                let density = LocalDensity.current
                // only on the shown -> hidden change: the keyboard comes up a few frames after the field takes focus
                LaunchedEffect(true) {
                    var shown = false
                    snapshotFlow { ime.getBottom(density) > 0 }
                    .distinctUntilChanged()
                    .collect { now in
                        if shown && !now { focusManager.clearFocus() }
                        shown = now
                    }
                }
                return Modifier.pointerInput(true) {
                    detectTapGestures(onTap: { _ in focusManager.clearFocus() })
                }
            }
        }
    }
}
#endif
