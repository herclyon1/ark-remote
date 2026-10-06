import SwiftUI
#if !os(Android) && canImport(UIKit)
import UIKit
#endif

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
    /// iOS: a 完成 key over the keyboard. The number pads (.numberPad) have no return key, and tapping blank space or
    /// dragging the list did not hide them either: the keyboard covered the tab bar until the App was restarted (test
    /// pass 1, 问题 3). One per page, on its List: keyboard toolbar items from several views add up. resignFirstResponder
    /// sent to the first responder, so no page has to bind its fields' @FocusState here (their blur checks still run on
    /// the focus change). Android's keypad has its own ✓ (IME action) and clearsFocusOnOutsideTap.
    func keyboardDone() -> some View {
        #if !os(Android) && canImport(UIKit)
        modifier(KeyboardDoneBar())
        #else
        self
        #endif
    }
}

#if !os(Android) && canImport(UIKit)
/// keyboardDone() on iOS. Since iOS 26 the .keyboard toolbar is a floating glass capsule that is not part of the
/// keyboard's safe area (developer.apple.com/forums/thread/797250 and /thread/799692), so the List scrolled a focused
/// field near the page end only to the keyboard's top edge, under the capsule: 鸣潮 「周本打第几个」 at y 599–621 behind
/// 完成 at 593–629, the typed number unseen (test pass 6, iOS 27). While a keyboard is up the List gets that much more
/// bottom safe area, so a last row can scroll above the capsule. That room alone did not keep fields clear: the system
/// scroll stops at a List edge that moves from test to test (the 0.4.4 final pass had 终末地 循环执行 behind 完成 with
/// it), so KeyboardRowReveal moves the focused row above the keyboard's end frame. The toolbar stays the system one:
/// no API puts it into the keyboard safe area or gives its height (DTS on thread/797250 suggests safeAreaBar instead,
/// whose @FocusState does not work on iOS 26.1, release notes 158720838).
private struct KeyboardDoneBar: ViewModifier {
    @State private var keyboardUp = false
    /// The 完成 capsule over the keyboard plus a gap: the capsule is 47 pt tall and sits on the keyboard's top edge
    /// (test pass 6 screenshot W1-3-kbd.png, iPhone 18 Pro Max, iOS 27). Measured, not from a system value (近似).
    private static let room: CGFloat = 56

    func body(content: Content) -> some View {
        content
            // set on keyboardWillShow, inside the keyboard's own animation, so it is in place when the List scrolls
            .safeAreaPadding(.bottom, keyboardUp ? Self.room : 0)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                KeyboardRowReveal.keyboardTop = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
                KeyboardRowReveal.shown(note)
            }
            // the first keystroke adds the row's 「待保存」 line and the row grows downwards
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { _ in
                DispatchQueue.main.async { KeyboardRowReveal.reveal() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}

/// Scrolls the focused field's whole row above the keyboard's top edge, 完成 capsule included. The system only scrolls
/// a field it finds outside the List's visible area, and only to that area's bottom edge, which on iOS 27 sits anywhere
/// from above to under the capsule: 循环执行 field at 543–565 above 完成 at 593–629, 周本打第几个 at 591–613 behind it,
/// the same build (List bottom insets 391 / 343 pt at keyboardDidShow). The keyboard's end frame
/// (keyboardFrameEndUserInfoKey) starts at the capsule's toolbar (y 587, iPhone 18 Pro Max, iOS 27), so a row ending
/// above it is clear of the capsule. Idempotent: nothing moves when the row is already clear, so each page's
/// keyboardDone() may call it for the same keyboard.
@MainActor enum KeyboardRowReveal {
    /// The keyboard's top edge in window coordinates while it is up (its end frame), nil while it is down.
    static var keyboardTop: CGFloat?
    private static let gap: CGFloat = 8

    static func shown(_ note: Notification) {
        guard let kb = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardTop = kb.minY
        reveal()
        // the List's own scroll to the field can still follow keyboardDidShow (seen: the row still at its old place
        // then) and stop with the row under the capsule; look again once it is done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reveal() }
    }

    static func reveal() {
        guard let top = keyboardTop, let field = FirstResponder.find() as? UIView else { return }
        var row: UIView = field
        var scroll: UIScrollView?
        var v = field.superview
        while let s = v {
            if s is UICollectionViewCell || s is UITableViewCell { row = s }
            if let sv = s as? UIScrollView { scroll = sv; break }
            v = s.superview
        }
        guard let scroll, let window = scroll.window else { return }
        let rowBottom = row.convert(row.bounds, to: window).maxY
        let over = rowBottom - (top - gap)
        guard over > 0.5 else { return }
        // no further than the List's end: the keyboardDone() bottom room is what lets a last row go that high
        let maxY = max(scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height,
                       -scroll.adjustedContentInset.top)
        let y = min(scroll.contentOffset.y + over, maxY)
        guard y > scroll.contentOffset.y + 0.5 else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
    }
}

/// The view that holds the keyboard focus (a UITextField inside a SwiftUI TextField): the first object to answer an
/// action sent to nil is the first responder.
@MainActor private enum FirstResponder {
    private static weak var found: UIResponder?
    static func find() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.arkCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    fileprivate static func set(_ r: UIResponder) { found = r }
}

extension UIResponder {
    @objc fileprivate func arkCaptureFirstResponder() { FirstResponder.set(self) }
}
#endif

extension View {
    /// The page's 放弃 (✕) also ends the editing: the field kept its focus and keyboard on Android, and the next tap on
    /// the keyboard typed into the reverted value and made a new 待保存 (test pass 5, 理智药 → 6). Android: the Compose
    /// focus is cleared when the press goes down (the Initial pass, before the button's click), so a field that checks
    /// its text on blur does so before the edits are dropped. iOS: the button's action calls endEditing() first.
    func endsEditingOnTap() -> some View {
        #if os(Android)
        composeModifier { ClearFocusOnPress() }
        #else
        self
        #endif
    }
}

/// iOS: hides the keyboard, as keyboardDone's 完成; the field's blur check runs on its focus change. Android: no-op,
/// endsEditingOnTap() does it there.
@MainActor func endEditing() {
    #if !os(Android) && canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
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
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.PointerEventPass
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

/// See `endsEditingOnTap()`. Watches the press in the Initial pass without consuming it, so the button still gets
/// its click.
struct ClearFocusOnPress: ContentModifier {
    func modify(view: any View) -> any View {
        view.composeModifier { modifier in
            modifier.composed {
                let focusManager = LocalFocusManager.current
                return Modifier.pointerInput(true) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed: false, pass: PointerEventPass.Initial)
                        focusManager.clearFocus()
                    }
                }
            }
        }
    }
}
#endif
