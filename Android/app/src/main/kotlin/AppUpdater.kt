package ark.remote

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/// In-app update from GitHub Releases.
///
/// check(): one GET of the latest release; when its tag is newer than BuildConfig.VERSION_NAME and it carries an
/// .apk asset, Swift shows 「有新版本 x.y.z」 (Sources/ArkRemote/Logic/AppUpdate.swift).
/// install(): download the APK into cacheDir, then hand it to the system with a PackageInstaller session
/// (https://developer.android.com/reference/android/content/pm/PackageInstaller). The result comes back to
/// UpdateStatusReceiver through the commit PendingIntent.
///
/// Swift calls these through the closures registered in start(); results go back through the bridged
/// ArkRemoteAppDelegate.onUpdate* methods. Nothing here runs on a timer.
object AppUpdater {
    private const val LATEST = "https://api.github.com/repos/herclyon1/ark-remote/releases/latest"
    internal const val ACTION_STATUS = "ark.remote.UPDATE_STATUS"

    private lateinit var app: Context
    private val checking = AtomicBoolean(false)
    internal val installing = AtomicBoolean(false)
    @Volatile private var apkURL: String? = null
    @Volatile private var latestVersion: String? = null

    private val delegate: ArkRemoteAppDelegate
        get() = ArkRemoteAppDelegate.shared

    /// AndroidAppMain.onCreate.
    fun start(context: Context) {
        app = context.applicationContext
        delegate.registerUpdater(check = { check() }, install = { install() })
    }

    /// One request; a failed check is only logged (no banner for a missed check).
    private fun check() {
        if (!checking.compareAndSet(false, true)) return
        thread(name = "ark-update-check") {
            try {
                val conn = URL(LATEST).openConnection() as HttpURLConnection
                conn.connectTimeout = 15_000
                conn.readTimeout = 15_000
                conn.setRequestProperty("Accept", "application/vnd.github+json")
                conn.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
                conn.setRequestProperty("User-Agent", "ark-remote/${BuildConfig.VERSION_NAME}")
                val code = conn.responseCode
                if (code != 200) {
                    logger.warning("update check: HTTP ${code}")
                    conn.disconnect()
                    return@thread
                }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val release = JSONObject(body)
                val tag = release.optString("tag_name")
                val version = tag.trim().removePrefix("v").removePrefix("V")
                val assets = release.optJSONArray("assets")
                var url: String? = null
                if (assets != null) {
                    for (i in 0 until assets.length()) {
                        val a = assets.getJSONObject(i)
                        if (a.optString("name").endsWith(".apk", ignoreCase = true)) {
                            url = a.optString("browser_download_url").takeIf { it.startsWith("https://") }
                            if (url != null) break
                        }
                    }
                }
                val current = BuildConfig.VERSION_NAME
                logger.info("update check: latest ${tag}, this build ${current}, apk ${url != null}")
                if (url != null && isNewer(version, current)) {
                    apkURL = url
                    latestVersion = version
                    delegate.onUpdateAvailable(version = version)
                }
            } catch (e: Exception) {
                logger.warning("update check failed: ${e}")
            } finally {
                checking.set(false)
            }
        }
    }

    /// 「更新」: the install permission first (no point downloading without it), then download and install.
    private fun install() {
        val url = apkURL ?: return
        if (!app.packageManager.canRequestPackageInstalls()) {
            delegate.onUpdateError(message = "请在设置里允许本应用「安装未知应用」，然后回来再点「更新」")
            try {
                val settings = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}"))
                settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                app.startActivity(settings)
            } catch (e: Exception) {
                logger.error("open unknown-app-sources settings failed: ${e}")
            }
            return
        }
        if (!installing.compareAndSet(false, true)) return
        val version = latestVersion ?: ""
        thread(name = "ark-update-install") {
            val file = try {
                download(url)
            } catch (e: Exception) {
                logger.error("update download failed: ${e}")
                installing.set(false)
                delegate.onUpdateError(message = "下载失败：" + downloadError(e))
                return@thread
            }
            try {
                delegate.onUpdateInstalling(message = "已下载，正在交给系统安装")
                commit(file, version)
            } catch (e: Exception) {
                logger.error("update install session failed: ${e}")
                installing.set(false)
                delegate.onUpdateError(message = "安装失败：无法建立安装会话")
            }
        }
    }

    private class HttpStatus(val code: Int) : IOException("HTTP ${code}")
    private class ShortDownload : IOException("short download")

    private fun downloadError(e: Exception): String = when (e) {
        is UnknownHostException -> "连不上网络"
        is SocketTimeoutException -> "网络超时"
        is HttpStatus -> "服务器返回 ${e.code}"
        is ShortDownload -> "文件没下载完整"
        is IOException -> "网络中断或存储空间不足"
        else -> "未知错误"
    }

    /// GitHub's browser_download_url redirects (https → https) to its object storage; HttpURLConnection follows it.
    private fun download(url: String): File {
        val dir = File(app.cacheDir, "update")
        dir.deleteRecursively()
        dir.mkdirs()
        val file = File(dir, "ark-remote.apk")
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.setRequestProperty("User-Agent", "ark-remote/${BuildConfig.VERSION_NAME}")
        try {
            val code = conn.responseCode
            if (code != 200) throw HttpStatus(code)
            val total = conn.contentLengthLong
            var done = 0L
            var lastPercent = -1L
            var lastBytes = 0L
            delegate.onUpdateProgress(done = 0, total = total.toInt())
            conn.inputStream.use { input ->
                file.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        // at most ~100 updates with a known size, one per MB without
                        val report = if (total > 0) {
                            val p = done * 100 / total
                            (p != lastPercent).also { if (it) lastPercent = p }
                        } else {
                            (done - lastBytes >= 1_048_576).also { if (it) lastBytes = done }
                        }
                        if (report) delegate.onUpdateProgress(done = done.toInt(), total = total.toInt())
                    }
                }
            }
            if (total > 0 && done != total) throw ShortDownload()
            delegate.onUpdateProgress(done = done.toInt(), total = (if (total > 0) total else done).toInt())
            logger.info("update downloaded: ${done} bytes")
        } finally {
            conn.disconnect()
        }
        return file
    }

    /// PackageInstaller session: SessionParams(MODE_FULL_INSTALL); on API 31+ setRequireUserAction(USER_ACTION_NOT_REQUIRED)
    /// (the app updating itself and holding UPDATE_PACKAGES_WITHOUT_USER_ACTION may then skip the confirm sheet;
    /// otherwise the receiver gets STATUS_PENDING_USER_ACTION). The commit PendingIntent is mutable because the
    /// system adds EXTRA_STATUS to it; it is explicit (our own receiver).
    private fun commit(file: File, version: String) {
        val installer = app.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(app.packageName)
        params.setSize(file.length())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                session.openWrite("ark-remote-${version}.apk", 0, file.length()).use { out ->
                    file.inputStream().use { it.copyTo(out, 64 * 1024) }
                    session.fsync(out)
                }
                val intent = Intent(app, UpdateStatusReceiver::class.java).setAction(ACTION_STATUS)
                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(app, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }
            logger.info("update session ${sessionId} committed")
        } catch (e: Exception) {
            installer.abandonSession(sessionId)
            throw e
        }
    }

    /// "0.10.0" > "0.9.1"; a suffix after "-" or "+" is ignored.
    internal fun isNewer(latest: String, current: String): Boolean {
        fun parts(v: String) = v.trim().removePrefix("v").removePrefix("V")
            .substringBefore('-').substringBefore('+')
            .split('.').map { it.toIntOrNull() ?: 0 }
        val a = parts(latest)
        val b = parts(current)
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }
}

/// The PackageInstaller session result (AndroidManifest.xml, exported="false").
class UpdateStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AppUpdater.ACTION_STATUS) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val detail = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        logger.info("update session status ${status}: ${detail}")
        val delegate = ArkRemoteAppDelegate.shared
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirm == null) {
                    AppUpdater.installing.set(false)
                    delegate.onUpdateError(message = "安装失败：系统没有给出确认界面")
                    return
                }
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(confirm)
                    delegate.onUpdateInstalling(message = "请在系统弹出的界面里确认安装")
                } catch (e: Exception) {
                    logger.error("start install confirmation failed: ${e}")
                    AppUpdater.installing.set(false)
                    delegate.onUpdateError(message = "安装失败：打不开系统的确认界面")
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // the system usually stops this process to replace the app before this arrives
                AppUpdater.installing.set(false)
                delegate.onUpdateInstalling(message = "安装完成，请重新打开")
            }
            else -> {
                AppUpdater.installing.set(false)
                delegate.onUpdateError(message = installError(status))
            }
        }
    }

    private fun installError(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED -> "已取消安装"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "安装失败：被系统拦下"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "安装失败：与已装的版本冲突（签名不同？）"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "安装失败：与本机不兼容"
        PackageInstaller.STATUS_FAILURE_INVALID -> "安装失败：安装包无效"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "安装失败：存储空间不足"
        else -> "安装失败"
    }
}
