package ark.remote

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/// The ntfy `/json` stream for Live.swift's NtfyStream (Android), read with Android's own HTTP stack: one thread per
/// stream blocks in BufferedReader.readLine() on the socket, so an idle open stream costs no CPU.
///
/// Before 0.5.2 the stream was a FoundationNetworking URLSessionDataTask (libcurl's multi interface driven by
/// libdispatch sources). With the stream open and quiet, libdispatch's worker threads woke its event-manager thread
/// thousands of times a second (eventfd_write → epoll_pwait, 23-32 % of a core on ark37; ~0 with no stream), measured
/// in 0.5.2 r3 (BOARD/app-work/0.5.2/r3/idle-cpu, r4). A blocking read has no event loop to spin.
///
/// Swift opens and closes streams through the closures registered at startup (registerStreamer); each stream has the
/// generation number Swift gave it, and its lines and its end go back with that number (onStreamLine / onStreamEnd)
/// on the stream's own thread.
internal object NtfyStreamer {
    private val open = ConcurrentHashMap<Int, StreamReader>()

    /// AndroidAppMain.onCreate.
    fun start() {
        ArkRemoteAppDelegate.shared.registerStreamer(
            open = { gen, url -> open(gen, url) },
            close = { gen -> open.remove(gen)?.close() })
    }

    private fun open(gen: Int, url: String) {
        val delegate = ArkRemoteAppDelegate.shared
        val reader = StreamReader(url,
            onLine = { line -> delegate.onStreamLine(gen = gen, line = line) },
            onEnd = { error -> open.remove(gen); delegate.onStreamEnd(gen = gen, error = error) })
        open[gen] = reader
        thread(name = "ark-ntfy-stream-${gen}", isDaemon = true) { reader.run() }
    }
}

/// One HTTP GET read line by line until the server ends it, the connection fails, or close() is called (from any
/// thread: disconnect() closes the socket, which ends the blocked read). onEnd is called exactly once, with "" for a
/// clean end of the body and the failure's message otherwise; a close() before the end still ends with onEnd.
internal class StreamReader(
    private val url: String,
    private val onLine: (String) -> Unit,
    private val onEnd: (String) -> Unit,
) {
    @Volatile private var conn: HttpURLConnection? = null
    @Volatile private var closed = false

    fun close() {
        closed = true
        conn?.disconnect()
    }

    fun run() {
        var error = ""
        try {
            val c = URL(url).openConnection() as HttpURLConnection
            conn = c
            if (closed) { c.disconnect(); throw java.io.IOException("closed") }
            c.useCaches = false
            c.connectTimeout = 15_000
            // the request's idle timeout as on iOS (Live.swift: timeoutInterval 24 h); ntfy writes a keepalive every 45 s
            c.readTimeout = 24 * 3600 * 1000
            // a live stream: no transparent gzip, which would hold lines back until a compressed block fills
            c.setRequestProperty("Accept-Encoding", "identity")
            c.setRequestProperty("Cache-Control", "no-store")
            val code = c.responseCode
            if (code !in 200..299) throw java.io.IOException("HTTP ${code}")
            if (closed) throw java.io.IOException("closed")
            BufferedReader(InputStreamReader(c.inputStream, Charsets.UTF_8)).use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    if (closed) break
                    if (line.isNotEmpty()) onLine(line)
                }
            }
        } catch (e: Exception) {
            error = if (closed) "closed" else (e.message ?: e.toString())
        } finally {
            conn?.disconnect()
        }
        onEnd(error)
    }
}
