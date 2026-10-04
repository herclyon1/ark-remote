package ark.remote

import skip.lib.*
import skip.model.*
import skip.foundation.*
import skip.ui.*

import android.Manifest
import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.graphics.Color as AndroidColor
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.ComponentActivity
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.MaterialTheme
import androidx.core.app.ActivityCompat

internal val logger: SkipLogger = SkipLogger(subsystem = "ark.remote", category = "ArkRemote")

private typealias AppRootView = ArkRemoteRootView
private typealias AppDelegate = ArkRemoteAppDelegate

/// AndroidAppMain is the `android.app.Application` entry point, and must match `application android:name` in the AndroidMainfest.xml file.
open class AndroidAppMain: Application {
    constructor() {
    }

    override fun onCreate() {
        super.onCreate()
        logger.info("starting app")
        ProcessInfo.launch(applicationContext)
        AppDelegate.shared.onInit()
        // crash-rec (Logic/CrashRec.swift): keep an uncaught exception's message and stack, then let the previous handler kill the app
        val prevHandler = java.lang.Thread.getDefaultUncaughtExceptionHandler()
        java.lang.Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try { AppDelegate.shared.onUncaughtException(e.toString(), android.util.Log.getStackTraceString(e)) } catch (_: Throwable) {}
            prevHandler?.uncaughtException(t, e)
        }
        // crash-rec: earlier runs' ANRs (AnrScan below; CrashRec.start runs the scan) and the version this run leaves for the next scan
        AnrScan.start(this)
        // the system share panel with its result for the 诊断记录 / 自检结果 sheet (ShareSheet.kt)
        ShareSheet.start(this)
        watchNetwork()
        // in-app update from GitHub Releases (AppUpdater.kt); hands Swift the check / install entry points
        AppUpdater.start(this)
    }

    /// navigator.onLine / online / offline: the system's default-network callback, event-driven (no timer,
    /// no polling, no request). registerDefaultNetworkCallback reports nothing when there is no network at
    /// registration, so the starting state is read once from activeNetwork. On a handover (Wi-Fi → mobile)
    /// onLost for the old network can come while the new one is already the default, so onLost re-reads it.
    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        AppDelegate.shared.onNetwork(cm.activeNetwork != null)
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                AppDelegate.shared.onNetwork(true)
            }

            override fun onLost(network: Network) {
                AppDelegate.shared.onNetwork(cm.activeNetwork != null)
            }
        })
    }

    companion object {
    }
}

/// AndroidAppMain is initial `androidx.appcompat.app.AppCompatActivity`, and must match `activity android:name` in the AndroidMainfest.xml file.
open class MainActivity: AppCompatActivity {
    constructor() {
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        logger.info("starting activity")
        ShareSheet.activity = java.lang.ref.WeakReference(this)
        UIApplication.launch(this)
        enableEdgeToEdge()

        setContent {
            val saveableStateHolder = rememberSaveableStateHolder()
            saveableStateHolder.SaveableStateProvider(true) {
                PresentationRootView(ComposeContext())
                SideEffect { saveableStateHolder.removeState(true) }
            }
        }

        AppDelegate.shared.onLaunch()

        // fluency-rec's UI-commit signal for slow / inp (FluencyRec.swift header): the view tree about to be drawn, handed over
        // only within DRAW_WATCH_MS of the last press (a gesture lasts at most 10 s). The listener stays for the activity's
        // life: one may not be added or removed inside onDraw (ViewTreeObserver.OnDrawListener).
        window.decorView.viewTreeObserver.addOnDrawListener {
            if (android.os.SystemClock.uptimeMillis() - lastDownAt < DRAW_WATCH_MS) AppDelegate.shared.onDraw()
        }

        // Example of requesting permissions on startup.
        // These must match the permissions in the AndroidManifest.xml file.
        //let permissions = listOf(
        //    Manifest.permission.ACCESS_COARSE_LOCATION,
        //    Manifest.permission.ACCESS_FINE_LOCATION
        //    Manifest.permission.CAMERA,
        //    Manifest.permission.WRITE_EXTERNAL_STORAGE,
        //)
        //let requestTag = 1
        //ActivityCompat.requestPermissions(self, permissions.toTypedArray(), requestTag)
    }

    /// Touch feed for crash-rec actions and the fluency lines (AppDelegate.onTouch): down / up / cancel of the primary
    /// pointer, in dp, with how late the event reached the main thread.
    private val DRAW_WATCH_MS = 11_000L
    private var lastDownAt = -DRAW_WATCH_MS

    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
        if (ev.actionMasked == android.view.MotionEvent.ACTION_DOWN) lastDownAt = android.os.SystemClock.uptimeMillis()
        val phase = when (ev.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> 0
            android.view.MotionEvent.ACTION_UP -> 1
            android.view.MotionEvent.ACTION_CANCEL -> 2
            else -> -1
        }
        if (phase >= 0) {
            val d = resources.displayMetrics.density
            AppDelegate.shared.onTouch(phase, (ev.x / d).toDouble(), (ev.y / d).toDouble(),
                (android.os.SystemClock.uptimeMillis() - ev.eventTime).toDouble())
        }
        return super.dispatchTouchEvent(ev)
    }

    override fun onStart() {
        logger.info("onStart")
        super.onStart()
    }

    override fun onResume() {
        super.onResume()
        ShareSheet.activity = java.lang.ref.WeakReference(this)
        ShareSheet.resumed()
        AppDelegate.shared.onResume()
    }

    override fun onPause() {
        super.onPause()
        ShareSheet.paused()
        AppDelegate.shared.onPause()
    }

    // Android 10+ serves the clipboard only to the app whose window has focus, which comes after onResume
    // (ClipboardService: "Denying clipboard access … not in focus", ark37 2026-10-03); AppGlue reads it then.
    // Handed over with it: when the clip on the clipboard was put there (ClipDescription.getTimestamp, API 26,
    // System.currentTimeMillis base), 0 when there is none or it is not text. Only the description is looked at:
    // getPrimaryClipDescription reads no content, so Android 12+ shows no 「已粘贴」 notice for it (that notice comes
    // with getPrimaryClip, ClipboardService.showAccessNotificationLocked). AppGlue reads the content only for a
    // text clip from the last 10 minutes it has not read before.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        var clipAt = 0.0
        if (hasFocus) {
            val d = (getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)?.primaryClipDescription
            if (d != null && d.hasMimeType("text/*")) clipAt = d.timestamp.toDouble()
        }
        AppDelegate.shared.onWindowFocus(hasFocus, clipAt)
    }

    override fun onStop() {
        super.onStop()
        AppDelegate.shared.onStop()
    }

    override fun onDestroy() {
        super.onDestroy()
        AppDelegate.shared.onDestroy()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        AppDelegate.shared.onLowMemory()
    }

    override fun onRestart() {
        logger.info("onRestart")
        super.onRestart()
    }

    override fun onSaveInstanceState(outState: android.os.Bundle): Unit = super.onSaveInstanceState(outState)

    override fun onRestoreInstanceState(bundle: android.os.Bundle) {
        // Usually you restore your state in onCreate(). It is possible to restore it in onRestoreInstanceState() as well, but not very common. (onRestoreInstanceState() is called after onStart(), whereas onCreate() is called before onStart().
        logger.info("onRestoreInstanceState")
        super.onRestoreInstanceState(bundle)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: kotlin.Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        logger.info("onRequestPermissionsResult: ${requestCode}")
    }

    companion object {
    }
}

/// crash-rec's ANR line on Android (the iOS side is MetricKit's hang diagnostics, Logic/CrashRec.swift MetricSubscriber).
/// ActivityManager.getHistoricalProcessExitReasons (API 30) keeps the app's recent process exits; each one with
/// reason REASON_ANR ("应用无响应": the system killed the app after its main thread stopped answering) newer than the
/// last one reported goes to ArkRemoteAppDelegate.onPastAnr once, with the "main" thread's block of the ANR trace
/// (getTraceInputStream: every thread of the process, so only the first TRACE_MAX characters are read). The newest
/// reported timestamp is kept in SharedPreferences, written once per scan. ApplicationExitInfo carries no app version,
/// so every run writes its own into setProcessStateSummary (API 30, ≤ 128 bytes) and the next scan reads it back
/// (getProcessStateSummary); exits from runs before this build carry none, sent as "". Below API 30 nothing is done.
internal object AnrScan {
    private const val PREFS = "ark-crash-anr"
    private const val SEEN = "seen"
    private const val TRACE_MAX = 64 * 1024

    @Volatile private var app: Context? = null

    /// AndroidAppMain.onCreate: this run's version into the process state summary, and the scan handed to Swift.
    fun start(context: Context) {
        app = context.applicationContext
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return
        try {
            val am = context.getSystemService(android.app.ActivityManager::class.java)
            am?.setProcessStateSummary(version().toByteArray(Charsets.UTF_8).let { if (it.size > 128) it.copyOf(128) else it })
        } catch (e: Throwable) {
            logger.warning("process state summary not set: ${e}")
        }
        AppDelegate.shared.registerAnrScan(scan = { scan() })
    }

    /// RecKit.version's format: "name (code)", or the name alone when the two are the same.
    private fun version(): String {
        val name = BuildConfig.VERSION_NAME
        val code = BuildConfig.VERSION_CODE.toString()
        return if (code.isEmpty() || code == name) name else "${name} (${code})"
    }

    private fun scan() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.R) return
        val ctx = app ?: return
        kotlin.concurrent.thread(name = "ark-anr-scan") {
            try {
                val am = ctx.getSystemService(android.app.ActivityManager::class.java) ?: return@thread
                val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val seen = prefs.getLong(SEEN, 0L)
                val anrs = am.getHistoricalProcessExitReasons(ctx.packageName, 0, 0)
                    .filter { it.reason == android.app.ApplicationExitInfo.REASON_ANR && it.timestamp > seen }
                    .sortedBy { it.timestamp }
                if (anrs.isEmpty()) return@thread
                prefs.edit().putLong(SEEN, anrs.last().timestamp).apply()
                for (x in anrs) {
                    val prevV = try { x.processStateSummary?.toString(Charsets.UTF_8) ?: "" } catch (_: Throwable) { "" }
                    val stack = try { mainThread(x) } catch (e: Throwable) { "trace not read: ${e}" }
                    logger.info("ANR of an earlier run at ${x.timestamp} (v ${prevV}): ${x.description}")
                    AppDelegate.shared.onPastAnr(x.timestamp.toDouble(), stack, prevV, x.description ?: "")
                }
            } catch (e: Throwable) {
                logger.warning("ANR scan failed: ${e}")
            }
        }
    }

    /// The `"main" …` block of the ANR trace (up to the blank line that ends it); the trace's first lines when no
    /// main block is within TRACE_MAX characters; "" when the system kept no trace.
    private fun mainThread(x: android.app.ApplicationExitInfo): String {
        val input = x.traceInputStream ?: return ""
        input.bufferedReader(Charsets.UTF_8).use { r ->
            val head = StringBuilder()
            val main = StringBuilder()
            var read = 0
            var inMain = false
            while (read < TRACE_MAX) {
                val line = r.readLine() ?: break
                read += line.length + 1
                if (inMain) {
                    if (line.isBlank()) break
                    main.append(line).append('\n')
                } else if (line.startsWith("\"main\"")) {
                    inMain = true
                    main.append(line).append('\n')
                } else if (head.length < 3000) {
                    head.append(line).append('\n')
                }
            }
            return if (main.isNotEmpty()) main.toString() else head.toString()
        }
    }
}

@Composable
internal fun SyncSystemBarsWithTheme() {
    val dark = MaterialTheme.colorScheme.background.luminance() < 0.5f

    val transparent = AndroidColor.TRANSPARENT
    val style = if (dark) {
        SystemBarStyle.dark(transparent)
    } else {
        SystemBarStyle.light(transparent, transparent)
    }

    val activity = LocalContext.current as? ComponentActivity
    DisposableEffect(style) {
        activity?.enableEdgeToEdge(
            statusBarStyle = style,
            navigationBarStyle = style
        )
        onDispose { }
    }
}

@Composable
internal fun PresentationRootView(context: ComposeContext) {
    val colorScheme = if (isSystemInDarkTheme()) ColorScheme.dark else ColorScheme.light
    PresentationRoot(defaultColorScheme = colorScheme, context = context) { ctx ->
        SyncSystemBarsWithTheme()
        val contentContext = ctx.content()
        Box(modifier = ctx.modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            AppRootView().Compose(context = contentContext)
        }
    }
}
