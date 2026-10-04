package ark.remote

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.lang.ref.WeakReference

/// The system share panel for 分享 on the 诊断记录 / 自检结果 sheet (Pages/Phone/DiagShare.swift), with what Android
/// can say about the outcome. The web's 分享 (view.js showDiagSheet) says every outcome: 「已交给分享」, 「分享已取消」,
/// 「分享没成」; Android's chooser reports less:
///   · picked: Intent.createChooser(target, title, IntentSender) sends the IntentSender, with EXTRA_CHOSEN_COMPONENT,
///     when the user picks an app (API 22+). That is all the chooser tells: whether the picked app then sent anything
///     is not reported back (ACTION_SEND has no result), so 「已交给分享」 means "handed to an app", as on the web;
///   · back without a pick: the chooser has no cancel callback. It is inferred here: the activity paused for the
///     chooser and resumed with no pick for CANCEL_WAIT_MS (the pick is sent when it is made, before the picked app
///     opens, so it is in by the time the user comes back). A pick reported later than that is dropped;
///   · could not open: startActivity threw (no activity, a record too large for the binder, …) → the message.
/// Swift calls share() through the closure registered at startup (registerSharer); results go back through
/// ArkRemoteAppDelegate.onShareResult on the main thread. All state here is touched on the main thread only.
internal object ShareSheet {
    internal const val ACTION_CHOSEN = "ark.remote.SHARE_CHOSEN"
    private const val CANCEL_WAIT_MS = 1000L

    /// MainActivity, set in its onCreate / onResume: the chooser is started from the activity, not the application.
    @Volatile internal var activity: WeakReference<Activity>? = null

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    /// a chooser was opened and nothing has been reported for it yet
    private var waiting = false
    /// the activity paused after the chooser was opened (the chooser came up)
    private var left = false
    private var seq = 0

    /// AndroidAppMain.onCreate.
    fun start(context: Context) {
        app = context.applicationContext
        ArkRemoteAppDelegate.shared.registerSharer(share = { text, title -> main.post { share(text, title) } })
    }

    private fun share(text: String, title: String) {
        val act = activity?.get()
        if (act == null || act.isFinishing) {
            tell(2, "没有可以弹出分享面板的界面")
            return
        }
        seq += 1
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            putExtra(Intent.EXTRA_SUBJECT, title)
        }
        // explicit (our own receiver) and mutable: the system adds EXTRA_CHOSEN_COMPONENT to it
        val back = Intent(app, ShareChosenReceiver::class.java).setAction(ACTION_CHOSEN).putExtra("seq", seq)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
        try {
            val pending = PendingIntent.getBroadcast(app, 0, back, flags)
            waiting = true
            left = false
            act.startActivity(Intent.createChooser(send, title, pending.intentSender))
        } catch (e: Throwable) {
            waiting = false
            logger.warning("share chooser not opened: ${e}")
            tell(2, e.message ?: e.toString())
        }
    }

    /// ShareChosenReceiver: the user picked `component`.
    internal fun chosen(component: ComponentName?, forSeq: Int) {
        if (!waiting || forSeq != seq) return
        waiting = false
        logger.info("share handed to ${component?.flattenToShortString()}")
        tell(0, component?.packageName ?: "")
    }

    /// MainActivity.onPause.
    fun paused() {
        if (waiting) left = true
    }

    /// MainActivity.onResume: back from the chooser; no pick within CANCEL_WAIT_MS = it was dismissed.
    fun resumed() {
        if (!waiting || !left) return
        val mine = seq
        main.postDelayed({
            if (waiting && seq == mine) {
                waiting = false
                tell(1, "")
            }
        }, CANCEL_WAIT_MS)
    }

    private fun tell(state: Int, message: String) {
        try { ArkRemoteAppDelegate.shared.onShareResult(state, message) } catch (e: Throwable) { logger.warning("share result not delivered: ${e}") }
    }
}

/// The chooser's pick (ShareSheet). Declared in AndroidManifest.xml, not exported.
class ShareChosenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ShareSheet.ACTION_CHOSEN) return
        val component: ComponentName? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT, ComponentName::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT)
        }
        ShareSheet.chosen(component, intent.getIntExtra("seq", -1))
    }
}
