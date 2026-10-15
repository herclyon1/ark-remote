package ark.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/// NtfyStreamer.kt StreamReader, the ntfy stream's blocking reader (0.5.2: replaced the FoundationNetworking data task
/// that kept a core busy while the stream was idle). Served by a one-connection HTTP server on 127.0.0.1.
class StreamReaderTest {
    /// Answers one request with `head` and then `body`, holding the connection open for `holdMs` before closing it.
    private fun serve(head: String, body: String, holdMs: Long): ServerSocket {
        val server = ServerSocket(0)
        thread(isDaemon = true) {
            server.accept().use { s ->
                val input = s.getInputStream().bufferedReader()
                while (true) { val l = input.readLine() ?: break; if (l.isEmpty()) break }
                val out = s.getOutputStream()
                out.write((head + body).toByteArray(Charsets.UTF_8))
                out.flush()
                Thread.sleep(holdMs)
            }
        }
        return server
    }

    private fun chunk(s: String): String {
        val b = s.toByteArray(Charsets.UTF_8)
        return Integer.toHexString(b.size) + "\r\n" + s + "\r\n"
    }

    private val chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"

    @Test
    fun linesArriveWhileTheStreamStaysOpenAndCloseEndsIt() {
        val server = serve(chunked, chunk("{\"event\":\"open\"}\n") + chunk("{\"event\":\"message\",\"id\":\"a\"}\n\n"), 30_000)
        val lines = Collections.synchronizedList(mutableListOf<String>())
        val two = CountDownLatch(2)
        val ended = CountDownLatch(1)
        var endedWith: String? = null
        val r = StreamReader("http://127.0.0.1:${server.localPort}/t/json",
            onLine = { lines.add(it); two.countDown() },
            onEnd = { endedWith = it; ended.countDown() })
        thread(isDaemon = true) { r.run() }
        assertTrue("both lines while the body is still open", two.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("{\"event\":\"open\"}", "{\"event\":\"message\",\"id\":\"a\"}"), lines.toList())
        assertEquals("not ended while the server holds the stream", 1L, ended.count)
        r.close()
        assertTrue("close() ends the blocked read", ended.await(5, TimeUnit.SECONDS))
        assertEquals("closed", endedWith)
        server.close()
    }

    @Test
    fun theServerEndingTheBodyEndsCleanly() {
        val server = serve(chunked, chunk("{\"event\":\"keepalive\"}\n") + "0\r\n\r\n", 0)
        val lines = Collections.synchronizedList(mutableListOf<String>())
        val ended = CountDownLatch(1)
        var endedWith: String? = null
        val r = StreamReader("http://127.0.0.1:${server.localPort}/t/json",
            onLine = { lines.add(it) }, onEnd = { endedWith = it; ended.countDown() })
        thread(isDaemon = true) { r.run() }
        assertTrue(ended.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("{\"event\":\"keepalive\"}"), lines.toList())
        assertEquals("", endedWith)
        server.close()
    }

    @Test
    fun anHttpErrorEndsWithItsStatus() {
        val server = serve("HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n", "", 0)
        val ended = CountDownLatch(1)
        var endedWith: String? = null
        val r = StreamReader("http://127.0.0.1:${server.localPort}/t/json",
            onLine = { }, onEnd = { endedWith = it; ended.countDown() })
        thread(isDaemon = true) { r.run() }
        assertTrue(ended.await(5, TimeUnit.SECONDS))
        assertEquals("HTTP 429", endedWith)
        server.close()
    }
}
