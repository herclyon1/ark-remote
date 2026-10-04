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
    override fun dispatchTouchEvent(ev: android.view.MotionEvent): Boolean {
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
        AppDelegate.shared.onResume()
    }

    override fun onPause() {
        super.onPause()
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
