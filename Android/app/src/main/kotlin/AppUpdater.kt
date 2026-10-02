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
/// install(): the APK in cacheDir/update/ark-remote-<version>.apk, downloaded once (cachedApk), then handed to the
/// system with a PackageInstaller session (https://developer.android.com/reference/android/content/pm/PackageInstaller).
/// The result comes back to UpdateStatusReceiver through the commit PendingIntent.
///
/// One download per version (user 10-02 19:06: it had to download twice before it installed): the file is kept
/// through every failure, cancel and retry and is only checked against the release asset's `size`; a cut-off
/// download stays as `.part` and resumes with a Range request. Files of versions this build already is (or is
/// past), and of versions that are no longer the latest, are deleted.
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
    /// The release asset's `size` in bytes (0 when GitHub gave none).
    @Volatile private var apkSize: Long = 0
    /// The session waiting on the system's confirm sheet; abandoned when 「继续安装」 commits a new one.
    @Volatile internal var waitingSession: Int = -1
    /// The session committed without the confirm sheet (setRequireUserAction NOT_REQUIRED), and the ones we abandoned.
    /// Xiaomi HyperOS refuses silent self-updates from installers it hasn't allowlisted and aborts the session
    /// (INSTALL_FAILED_ABORTED: Permission denied — https://github.com/sofianeelhor/PKForge/issues/25), which showed as
    /// 「安装被取消了」 on the user's Redmi (10-02 23:2x 「每次都会弹出来这个，我都不知道为什么」). An abort of the
    /// silent session is answered by committing again with the sheet; an abort of an abandoned one is ours, not news.
    @Volatile internal var silentSession: Int = -1
    @Volatile private var silentRefused = false
    internal val abandoned: MutableSet<Int> = java.util.Collections.synchronizedSet(mutableSetOf())

    private val delegate: ArkRemoteAppDelegate
        get() = ArkRemoteAppDelegate.shared

    /// AndroidAppMain.onCreate.
    fun start(context: Context) {
        app = context.applicationContext
        delegate.registerUpdater(check = { check() }, install = { install() })
        thread(name = "ark-update-clean") { prune(keep = null) }
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
                var size = 0L
                if (assets != null) {
                    for (i in 0 until assets.length()) {
                        val a = assets.getJSONObject(i)
                        if (a.optString("name").endsWith(".apk", ignoreCase = true)) {
                            url = a.optString("browser_download_url").takeIf { it.startsWith("https://") }
                            size = a.optLong("size", 0L)
                            if (url != null) break
                        }
                    }
                }
                val current = BuildConfig.VERSION_NAME
                logger.info("update check: latest ${tag}, this build ${current}, apk ${url != null}")
                if (url != null && isNewer(version, current)) {
                    apkURL = url
                    latestVersion = version
                    apkSize = size
                    prune(keep = version)
                    delegate.onUpdateAvailable(version = version, canInstall = app.packageManager.canRequestPackageInstalls())
                } else {
                    prune(keep = null)
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
            delegate.onUpdateNeedsPermission()
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
        val size = apkSize
        thread(name = "ark-update-install") {
            val file = try {
                cachedApk(url, version, size)
            } catch (e: Exception) {
                logger.error("update download failed: ${e}")
                installing.set(false)
                delegate.onUpdateError(message = "下载没完成：" + downloadError(e))
                return@thread
            }
            try {
                delegate.onUpdateInstalling(message = "已下载，正在交给系统安装")
                commit(file, version)
            } catch (e: Exception) {
                logger.error("update install session failed: ${e}")
                installing.set(false)
                delegate.onUpdateError(message = "系统没接下安装（无法建立安装会话）")
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

    private fun updateDir(): File = File(app.cacheDir, "update").also { it.mkdirs() }
    private fun apkFile(version: String) = File(updateDir(), "ark-remote-${version}.apk")

    /// Deletes the kept files that can no longer be installed: versions this build is at or past, every version but
    /// `keep` (the latest release) once that is known, and the old single "ark-remote.apk" of 0.3.0–0.3.3.
    private fun prune(keep: String?) {
        try {
            val current = BuildConfig.VERSION_NAME
            for (f in updateDir().listFiles() ?: emptyArray()) {
                val v = Regex("^ark-remote-(.+?)\\.apk(\\.part)?$").find(f.name)?.groupValues?.get(1)
                val stale = v == null || !isNewer(v, current) || (keep != null && v != keep)
                if (stale && f.delete()) logger.info("update cache: deleted ${f.name}")
            }
        } catch (e: Exception) {
            logger.warning("update cache prune failed: ${e}")
        }
    }

    /// The APK of `version`: the kept file when it is complete (its length is the release asset's `size`), otherwise
    /// downloaded — resuming a cut-off `.part` with a Range request when there is one. Nothing here deletes a file
    /// on failure: a failed, cancelled or refused install leaves it for the next tap.
    private fun cachedApk(url: String, version: String, size: Long): File {
        val file = apkFile(version)
        if (file.exists()) {
            if (size <= 0 || file.length() == size) {
                logger.info("update: reusing ${file.name} (${file.length()} bytes)")
                delegate.onUpdateProgress(done = file.length().toInt(), total = file.length().toInt())
                return file
            }
            logger.warning("update: ${file.name} is ${file.length()} bytes, release says ${size}; downloading again")
            file.delete()
        }
        val part = File(updateDir(), file.name + ".part")
        download(url, part, size)
        if (size > 0 && part.length() != size) throw ShortDownload()
        if (!part.renameTo(file)) throw IOException("rename ${part.name}")
        return file
    }

    /// GitHub's browser_download_url redirects (https → https) to its object storage; HttpURLConnection follows it
    /// and sends the Range header there too. 206 = resumed, 200 = the server sent the whole file (start over).
    private fun download(url: String, part: File, size: Long) {
        var start = if (part.exists()) part.length() else 0L
        if (size > 0 && start >= size) { part.delete(); start = 0L }
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.setRequestProperty("User-Agent", "ark-remote/${BuildConfig.VERSION_NAME}")
        if (start > 0) conn.setRequestProperty("Range", "bytes=${start}-")
        try {
            val code = conn.responseCode
            val append = when (code) {
                206 -> true
                200 -> false
                else -> throw HttpStatus(code)
            }
            if (!append) start = 0L
            val total = if (size > 0) size else (if (conn.contentLengthLong > 0) start + conn.contentLengthLong else 0L)
            var done = start
            var lastPercent = -1L
            var lastBytes = start
            logger.info("update download: ${if (append) "resuming at ${start}" else "from 0"} of ${total}")
            delegate.onUpdateProgress(done = done.toInt(), total = total.toInt())
            conn.inputStream.use { input ->
                java.io.FileOutputStream(part, append).use { out ->
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
    }

    /// PackageInstaller session: SessionParams(MODE_FULL_INSTALL); on API 31+ setRequireUserAction(USER_ACTION_NOT_REQUIRED)
    /// (the app updating itself and holding UPDATE_PACKAGES_WITHOUT_USER_ACTION may then skip the confirm sheet;
    /// otherwise the receiver gets STATUS_PENDING_USER_ACTION). The commit PendingIntent is mutable because the
    /// system adds EXTRA_STATUS to it; it is explicit (our own receiver).
    private fun commit(file: File, version: String, silent: Boolean = !silentRefused) {
        val installer = app.packageManager.packageInstaller
        // 「继续安装」 while the last session still waits on its confirm sheet: drop that one, this one replaces it
        val old = waitingSession
        if (old >= 0) {
            waitingSession = -1
            abandoned.add(old)
            try { installer.abandonSession(old) } catch (e: Exception) { logger.warning("abandon session ${old}: ${e}") }
        }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(app.packageName)
        params.setSize(file.length())
        if (silent && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        silentSession = if (silent && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) sessionId else -1
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
            logger.info("update session ${sessionId} committed (silent ${silent})")
        } catch (e: Exception) {
            installer.abandonSession(sessionId)
            throw e
        }
    }

    /// The silent session was aborted by the system: same file, again, with the confirm sheet. False when there is
    /// nothing to retry (no kept file), so the receiver reports the failure instead.
    internal fun retryWithConfirm(): Boolean {
        silentRefused = true
        silentSession = -1
        val version = latestVersion ?: return false
        val file = apkFile(version)
        if (!file.isFile) return false
        thread(name = "ark-update-confirm") {
            try {
                commit(file, version, silent = false)
            } catch (e: Exception) {
                logger.error("update install session (confirm) failed: ${e}")
                installing.set(false)
                delegate.onUpdateError(message = "系统没接下安装（无法建立安装会话）")
            }
        }
        return true
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
        val session = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        logger.info("update session ${session} status ${status}: ${detail}")
        val delegate = ArkRemoteAppDelegate.shared
        if (session >= 0 && AppUpdater.abandoned.remove(session)) return   // we dropped it for a newer one
        if (status == PackageInstaller.STATUS_FAILURE_ABORTED && session >= 0 && session == AppUpdater.silentSession) {
            logger.info("silent update refused by the system; committing again with the confirm sheet")
            if (AppUpdater.retryWithConfirm()) return
        }
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                // the session now waits on the user; the lock goes so 「继续安装」 can bring the sheet back (a new session
                // from the kept file) if it was closed without an answer
                AppUpdater.installing.set(false)
                AppUpdater.waitingSession = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
                if (confirm == null) {
                    delegate.onUpdateError(message = "系统没有给出安装确认界面")
                    return
                }
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(confirm)
                    delegate.onUpdateConfirming()
                } catch (e: Exception) {
                    logger.error("start install confirmation failed: ${e}")
                    delegate.onUpdateError(message = "打不开系统的安装确认界面")
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // the system stops the old process to replace the app; this arrives in the new one (logcat 10-02 19:17:30,
                // a new pid), where there is nothing to say — the old 「安装完成，请重新打开」 was never true there
                AppUpdater.installing.set(false)
                AppUpdater.waitingSession = -1
                delegate.onUpdateInstalled()
            }
            else -> {
                AppUpdater.installing.set(false)
                AppUpdater.waitingSession = -1
                delegate.onUpdateError(message = installError(status))
            }
        }
    }

    private fun installError(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED -> "安装被取消了"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "系统拦下了这次安装"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "和已装的版本冲突（签名不同？）"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "和这台手机不兼容"
        PackageInstaller.STATUS_FAILURE_INVALID -> "安装包无效"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "手机存储空间不够"
        else -> "系统没装上"
    }
}
