package ark.remote

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import skip.ui.ComposeContext
import skip.ui.ComposeView
import skip.ui.Text

/// The 0.5.1 Android replay's SIGABRT at farm.done: "Could not cast value of type 'Swift.Optional<Any>' to
/// 'SkipBridge.SwiftEquatable'" in skip.ui View.onChange. skip-fuse-ui hands onChange a SwiftEquatable that is never
/// null, so the Kotlin side passed back a null old value: onChange's rememberSaveable restored null, because its row had
/// been saved through one ComposeStateSaver and restored through another (ComposeStateSaver keeps non-primitive values
/// in a map of its own instance). skip-ui's TagModifier.IdStateSaver handed a subtree a fresh saver for the one pass in
/// which its .id changed and the parent's saver on every later pass. StatusPage's List has .id(reselect): a reselect of
/// 状态, then a state that drops the 开始刷 row in the next pass, saved that row (its StatusAsking onChange) through the
/// fresh saver; when the row came back it was restored through the parent's, as null. These pin the vendored patch
/// (Vendor/skip-ui/VENDORED.md): an .id subtree uses one saver on every pass, so a row comes back with its value.
///
/// The App is not started: the plain Application keeps AndroidAppMain from loading the Swift libraries on the JVM.
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36], application = android.app.Application::class)
class IdStateSaverTest {
    @get:Rule val rule = createComposeRule()

    private val flag = mutableStateOf(0)
    private val show = mutableStateOf(true)
    private val tick = mutableStateOf(0)

    /// The farm.show / farm.done sequence, frame by frame (the emulator draws 2-3 frames a second, so a state can land
    /// in the frame right after a tap): the .id changes (the reselect tap of 状态), the next frame drops the row (the
    /// state with 刷声骸 running), a later one brings it back (the original state). The onChange value is
    /// non-primitive, as skip-fuse-ui's SwiftEquatable is (ComposeStateSaver keeps primitives in the Bundle itself), and
    /// never changes, so the action must not run. Old code: it ran once with a null old value - in the App, the bridge
    /// cast that fails (the SIGABRT).
    @Test
    fun aRowDroppedRightAfterAnIdChangeComesBackWithItsOnChangeValue() {
        val calls = mutableListOf<Pair<Any?, Any?>>()
        rule.setContent {
            val root = remember { ComposeContext() }   // one root context, as Main.kt's setContent composes once
            val f = flag.value
            val s = show.value
            ComposeView { ctx ->
                val holder = rememberSaveableStateHolder()   // a lazy list keeps its rows' state this way
                if (s) {
                    holder.SaveableStateProvider("row") {
                        Text(verbatim = "row").onChange(of = listOf("v"), initial = false) { old: Any?, new: Any? ->
                            calls.add(old to new)
                        }.Compose(ctx)
                    }
                }
            }.id(f).Compose(root)
        }
        rule.waitForIdle()
        rule.mainClock.autoAdvance = false
        flag.value = 1   // reselect: .id(reselect) changes
        nextFrame()
        show.value = false   // the next frame drops the row; the holder saves its state
        nextFrame()
        rule.mainClock.autoAdvance = true
        rule.waitForIdle()
        show.value = true   // the row comes back and restores its state
        rule.waitForIdle()
        assertEquals("onChange ran although its value never changed (old value null = the restore lost it)",
            emptyList<Pair<Any?, Any?>>(), calls)
    }

    /// The cause: every pass under an .id, the one in which the id changed included, hands the subtree one saver.
    /// Old code: the pass that changed the id used a fresh one, the next pass the parent's.
    @Test
    fun anIdSubtreeKeepsOneStateSaverAcrossPasses() {
        val savers = mutableListOf<Any>()
        rule.setContent {
            val root = remember { ComposeContext() }
            val f = flag.value
            tick.value
            ComposeView { ctx -> savers.add(ctx.stateSaver) }.id(f).Compose(root)
        }
        rule.waitForIdle()
        val before = savers.size
        flag.value = 1
        rule.waitForIdle()
        tick.value = 1   // an unrelated pass under the same id
        rule.waitForIdle()
        val since = savers.drop(before)
        assertTrue("no pass after the id change", since.size >= 2)
        assertEquals("passes after the id change used different savers",
            1, since.map { System.identityHashCode(it) }.distinct().size)
    }

    /// One frame: hand the pending state writes to the recomposer, then draw.
    private fun nextFrame() {
        Snapshot.sendApplyNotifications()
        rule.mainClock.advanceTimeByFrame()
    }
}
