package ark.remote

import android.content.pm.PackageInstaller
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// Regression list 0108 item 6 (user 10-02 19:06: it had to download twice before it installed). Xiaomi HyperOS aborts
/// the silent self-update; 4a552ae answers that abort by committing the kept file again with the confirm sheet.
/// These pin that decision (UpdateStatusReceiver → AppUpdater.sessionResult) and the version compare.
class AppUpdaterTest {
    private val aborted = PackageInstaller.STATUS_FAILURE_ABORTED

    @Test
    fun abortOfTheSilentSessionRetriesWithTheConfirmSheet() {
        assertEquals(AppUpdater.SessionResult.RETRY_WITH_CONFIRM,
            AppUpdater.sessionResult(aborted, session = 7, silentSession = 7, abandoned = false))
    }

    @Test
    fun abortOfASessionWithTheSheetIsReported() {
        // the user cancelled the confirm sheet: 「安装被取消了」, no retry loop
        assertEquals(AppUpdater.SessionResult.DISPATCH,
            AppUpdater.sessionResult(aborted, session = 7, silentSession = -1, abandoned = false))
        assertEquals(AppUpdater.SessionResult.DISPATCH,
            AppUpdater.sessionResult(aborted, session = 8, silentSession = 7, abandoned = false))
    }

    @Test
    fun abortWithoutASessionIdIsReported() {
        // both -1 must not read as "the silent session"
        assertEquals(AppUpdater.SessionResult.DISPATCH,
            AppUpdater.sessionResult(aborted, session = -1, silentSession = -1, abandoned = false))
    }

    @Test
    fun abortOfAnAbandonedSessionIsIgnored() {
        assertEquals(AppUpdater.SessionResult.IGNORE,
            AppUpdater.sessionResult(aborted, session = 7, silentSession = 7, abandoned = true))
        assertEquals(AppUpdater.SessionResult.IGNORE,
            AppUpdater.sessionResult(aborted, session = 7, silentSession = -1, abandoned = true))
    }

    @Test
    fun successAndOtherResultsAreNeverRetried() {
        for (status in listOf(PackageInstaller.STATUS_SUCCESS, PackageInstaller.STATUS_PENDING_USER_ACTION,
                PackageInstaller.STATUS_FAILURE, PackageInstaller.STATUS_FAILURE_BLOCKED)) {
            assertEquals("status ${status}", AppUpdater.SessionResult.DISPATCH,
                AppUpdater.sessionResult(status, session = 7, silentSession = 7, abandoned = false))
        }
    }

    @Test
    fun retryWithNothingKeptFallsBackToTheError() {
        // no checked release → no kept file → false, so the receiver reports the abort instead of hanging
        assertFalse(AppUpdater.retryWithConfirm())
        assertEquals(-1, AppUpdater.silentSession)
    }

    @Test
    fun versionCompare() {
        assertTrue(AppUpdater.isNewer("0.10.0", "0.9.1"))
        assertTrue(AppUpdater.isNewer("v1.2.1", "1.2"))
        assertFalse(AppUpdater.isNewer("0.3.6", "0.3.6"))
        assertFalse(AppUpdater.isNewer("1.2", "1.2.0"))
        assertFalse(AppUpdater.isNewer("1.2.3-beta", "1.2.3"))
        assertFalse(AppUpdater.isNewer("0.9.9", "0.10.0"))
    }
}
