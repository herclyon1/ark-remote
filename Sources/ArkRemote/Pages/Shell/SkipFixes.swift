import SwiftUI

// Places where the same SwiftUI code draws differently through Skip on Android, with the way around each.
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

/// A menu Picker with its title, for a row that is not the Picker alone (a VStack with the 「待保存」 line under it).
///
/// skip-ui draws a Picker's label only when the Picker is itself the list row (Picker.swift RenderListItem, :223-233);
/// one inside a VStack goes through Render, which shows only the picked value and drops the label "outside of a Form"
/// (Picker.swift:98-99), so on Android the row lost its name and hint. There the title sits on the left and the
/// label-less menu on the right, as iOS lays out a menu picker row.
@ViewBuilder
func menuPicker<Selection: Hashable, Content: View, Title: View>(selection: Binding<Selection>,
                                                                 @ViewBuilder content: @escaping () -> Content,
                                                                 @ViewBuilder title: @escaping () -> Title) -> some View {
    #if os(Android)
    HStack(spacing: 12) {
        title().frame(maxWidth: .infinity, alignment: .leading)
        // at most ~40 % of the row: a long choice (干员养成（作战记录、协议圆盘、…）) took the whole row and squeezed the title
        // to one character a line (the title's maxWidth .infinity is laid out after the picker); the choice wraps instead
        Picker(selection: selection, content: content, label: { EmptyView() })
            .pickerStyle(.menu)
            .frame(maxWidth: 150, alignment: .trailing)
    }
    #else
    Picker(selection: selection, content: content, label: title)
        .pickerStyle(.menu)
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

/// A list row that opens its page as a sheet from the bottom instead of pushing it: the web page's 勾选页 (#picker,
/// index.html:957-963; view.js:1458 openPicker, sheet.js) is a page sheet over the tab, not a pushed page. Used as
/// `NavigationLink` is: `SheetLink { EWChoiceList(…) } label: { … }`.
///
/// The sheet has its own navigation bar as #picker's .pnav: 「返回」 (chevron, view.js:1484 `.pback` = close, nothing
/// applied) on the left, the page's title small in the middle, and the page's own ✓ (完成, `.pdone`) on the right. A
/// swipe down closes it the same way (sheet.js drag-to-dismiss). The row keeps the disclosure chevron the pushed row
/// had (the web value row reads 「已选 N/M ›」).
struct SheetLink<Destination: View, Label: View>: View {
    let destination: () -> Destination
    let label: () -> Label
    @State var shown = false

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        Button {
            shown = true
        } label: {
            HStack {
                label()
                #if os(Android)
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                #else
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                #endif
            }
            // a row, not a tinted button: the label keeps the list's text colour (its own secondary parts stay secondary)
            .foregroundStyle(.primary)
            #if !os(Android)
            .contentShape(Rectangle())   // the whole row takes the tap (skip-fuse-ui has no contentShape; a Compose row is whole already)
            #endif
        }
        .sheet(isPresented: $shown) {
            NavigationStack {
                destination()
                    #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)   // .ptitle: the small centred title of a sheet's bar
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { shown = false } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("返回")   // index.html:960 .pback aria-label 返回
                        }
                    }
            }
            // the tab's toast layer is under the sheet (a sheet is its own presentation on both platforms); the web's
            // .toast sits over #picker, so 「至少要留一个…」 (EWChoiceList.done) shows here too. Both layers clear the same
            // Relay.toast by its `at`, so two of them never fight.
            .overlay { ToastLayer() }
        }
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
