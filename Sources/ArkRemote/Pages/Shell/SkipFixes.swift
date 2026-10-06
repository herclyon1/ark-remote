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

extension View {
    /// `.controlSize(.small)` (a row's in-place ProgressView). Android: skip-fuse-ui marks controlSize unavailable
    /// (View/AdditionalViewModifiers.swift:224-226), so the Material indicator keeps its own size there.
    @ViewBuilder func smallControl() -> some View {
        #if os(Android)
        self
        #else
        self.controlSize(.small)
        #endif
    }

    /// `.monospacedDigit()` (numbers that change in place). Android: skip-fuse-ui marks it unavailable
    /// (Text/Text.swift:347-350 and :433-436), so the digits keep the font's own widths there.
    @ViewBuilder func digitsMonospaced() -> some View {
        #if os(Android)
        self
        #else
        self.monospacedDigit()
        #endif
    }
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

/// A list row that pushes its page, as a settings row with a value does (HIG Lists and tables / Settings: a row that
/// leads to a choice list pushes it; the system draws the row's disclosure indicator and the page's back button). Kept
/// under its old name with the call site of `NavigationLink`: `SheetLink { EWChoiceList(…) } label: { … }`.
struct SheetLink<Destination: View, Label: View>: View {
    let destination: () -> Destination
    let label: () -> Label

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        NavigationLink(destination: destination, label: label)
    }
}

extension View {
    /// The keyboard's 完成 key and drag-to-dismiss, once per page on its List. The number pads (.numberPad) have no return
    /// key, and a drag of the list did not hide them either: the keyboard covered the tab bar until the App was restarted
    /// (test pass 1, 问题 3). `.scrollDismissesKeyboard(.interactively)` lets a drag of the list take the keyboard down
    /// (SwiftUI scrollDismissesKeyboard; skip-ui List.swift:181 reads it too). Keyboard toolbar items from several views
    /// add up, hence one per page. 完成 ends the editing of whichever field has focus; a page that owns its fields'
    /// `@FocusState` should use `keyboardDone(_:)` instead, which clears that state. Android's keypad has its own ✓ (IME
    /// action) and clearsFocusOnOutsideTap.
    func keyboardDone() -> some View {
        #if !os(Android) && canImport(UIKit)
        scrollDismissesKeyboard(.interactively).modifier(KeyboardDoneBar(done: nil))
        #else
        scrollDismissesKeyboard(.interactively)
        #endif
    }

    /// `keyboardDone()` for a page whose fields are bound to `focus`: 完成 sets it to nil (SwiftUI FocusState: "set the
    /// focused value to nil to remove focus from all bound fields").
    func keyboardDone<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if !os(Android) && canImport(UIKit)
        scrollDismissesKeyboard(.interactively).modifier(KeyboardDoneBar(done: { focus.wrappedValue = nil }))
        #else
        scrollDismissesKeyboard(.interactively)
        #endif
    }
}

#if !os(Android) && canImport(UIKit)
/// keyboardDone() on iOS: the system .keyboard toolbar with 完成, plus room for its capsule. Since iOS 26 the .keyboard toolbar is a floating glass capsule that is not part of the
/// keyboard's safe area (developer.apple.com/forums/thread/797250 and /thread/799692), so the List scrolled a focused
/// field near the page end only to the keyboard's top edge, under the capsule: 鸣潮 「周本打第几个」 at y 599–621 behind
/// 完成 at 593–629, the typed number unseen (test pass 6, iOS 27). While a keyboard is up the List gets that much more
/// bottom safe area, so a last row can scroll above the capsule. That room alone did not keep fields clear: the system
/// scroll stops at a List edge that moves from test to test (the 0.4.4 final pass had 终末地 循环执行 behind 完成 with
/// it), so KeyboardRowReveal moves the focused row above the keyboard's end frame. The toolbar stays the system one:
/// no API puts it into the keyboard safe area or gives its height (DTS on thread/797250 suggests safeAreaBar instead,
/// whose @FocusState does not work on iOS 26.1, release notes 158720838). Checked again 10-07 (iPhone 18 Pro Max, iOS 27)
/// with only the system .keyboard toolbar and the List's own keyboard avoidance (no room, no reveal): 终末地 基质刷取 ·
/// 循环执行 and 方舟 优先刷取的活动关卡序号 both ended with the value behind 完成.
private struct KeyboardDoneBar: ViewModifier {
    /// What 完成 does: clear the page's @FocusState, or (nil) end the editing of the focused field, for the pages that
    /// do not bind one here.
    let done: (() -> Void)?
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
            // the List's own scroll to the focused field can still run after keyboardDidShow and stop with the row under
            // the capsule; when that scroll ends (the scroll phase goes back to idle) the row is checked again. A drag by
            // the user ends this: a row scrolled away on purpose is not pulled back.
            .onScrollPhaseChange { _, phase in
                KeyboardRowReveal.phaseChanged(phase)
            }
            // the first keystroke adds the row's 「待保存」 line and the row grows downwards
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { _ in
                DispatchQueue.main.async { KeyboardRowReveal.reveal() }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        if let done { done() } else { endEditing() }
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
    static var keyboardTop: CGFloat? {
        didSet { if keyboardTop == nil { settling = false } }
    }
    /// From keyboardDidShow until the user drags the List: the List's own scroll to the field may still be on its way.
    private static var settling = false
    private static let gap: CGFloat = 8

    static func shown(_ note: Notification) {
        guard let kb = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardTop = kb.minY
        settling = true
        reveal()
    }

    /// The List's own scroll to the field can still follow keyboardDidShow (seen: the row still at its old place then)
    /// and stop with the row under the capsule; look again when a scroll ends (SwiftUI onScrollPhaseChange, phase idle),
    /// not after a fixed delay. A user's drag (phase interacting) stops the looking.
    static func phaseChanged(_ phase: ScrollPhase) {
        if phase == .interacting { settling = false }
        if phase == .idle, settling { reveal() }
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

    /// D39 on Android: a reselect of `tab` at its root (TabReselect.bump) also opens the large title again, as iOS's
    /// tab bar does when it scrolls a root page to its top. No-op on iOS. Goes on the tab's NavigationStack.
    ///
    /// The root page's new List (its .id(reselect)) starts at the top, but the title's collapse is not the List's: it is
    /// skip-ui's Compose LargeTopAppBar (Containers/Navigation.swift:512) with an exitUntilCollapsed scroll behavior
    /// remembered per navigation entry in RenderEntry (:242, :298), tied to the List only through nestedScroll (:323).
    /// So the title stayed collapsed over a list back at its top. skip-ui's public `material3TopAppBar` (:1493) hands
    /// that very behavior to its closure (:304-307), which is called before the entry's content is composed - so the
    /// modifier is read from the NavigationStack, not from the page.
    func expandsTopBarOnReselect(_ tab: ContentTab) -> some View {
        #if os(Android)
        composeModifier { ExpandTopBarOnReselect(tab: tab.reselectIndex) }
        #else
        self
        #endif
    }
}

extension ContentTab {
    /// The tab's slot in TopBarReselect (Android), whose bridged API takes an Int.
    var reselectIndex: Int {
        switch self {
        case .status: return 0
        case .arknights: return 1
        case .endfield: return 2
        case .wuwa: return 3
        case .phone: return 4
        }
    }
}

#if SKIP
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
/// The reselect counts as Compose state, for the top bar closure below. TabReselect (an @Observable in compiled Swift) is
/// not bridged to Kotlin (its TabReselect.kt has no class), and an environment value set on the NavigationStack did not
/// reach the tab roots on Android (TabReselect.swift:1-6), so TabReselect.bump bumps these too.
/// Public, not internal: Kotlin names an internal member `bump$ArkRemote` on the JVM, while the generated Swift bridge
/// looks the method up as `bump` and force-unwraps it - the first reselect trapped (SIGTRAP from the tab bar's click).
public final class TopBarReselect {
    private static let counts = [mutableIntStateOf(0), mutableIntStateOf(0), mutableIntStateOf(0), mutableIntStateOf(0), mutableIntStateOf(0)]

    public static func bump(_ tab: Int) {
        counts[tab].intValue += 1
    }

    /// Read in a composable: the reader recomposes on a bump.
    public static func value(_ tab: Int) -> Int {
        return counts[tab].intValue
    }
}

/// See `expandsTopBarOnReselect(_:)`. The closure is called twice per composition (Navigation.swift:305 and :494, the
/// second return value dropped at :497), both times with the entry's own scroll behavior, so it only resets the one it is
/// handed and never makes a new one. `seen` starts at the count of the first composition: an entry composed again
/// (back from another tab, its List scrolled where it was) does not open its title; only a later bump does.
// SKIP INSERT: @OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
struct ExpandTopBarOnReselect: ContentModifier {
    let tab: Int

    func modify(view: any View) -> any View {
        view.material3TopAppBar { options in
            let count = TopBarReselect.value(tab)
            let seen = remember { mutableStateOf(count) }
            let behavior = options.scrollBehavior
            LaunchedEffect(count) {
                if seen.value != count {
                    seen.value = count
                    if let b = behavior, !b.isPinned {
                        b.state.heightOffset = Float(0.0)
                        b.state.contentOffset = Float(0.0)
                    }
                }
            }
            return options
        }
    }
}
#endif
