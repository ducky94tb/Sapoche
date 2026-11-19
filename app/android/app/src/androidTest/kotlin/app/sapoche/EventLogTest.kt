package app.sapoche

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** What "Copy log" gives after a run that crashed, with a file standing in for what that run left. */
class EventLogTest {

    private lateinit var dir: File

    @Before
    fun folder() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        dir = File(context.cacheDir, "event-log-test").also { it.deleteRecursively(); it.mkdirs() }
    }

    @After
    fun restore() {
        dir.deleteRecursively()
        // The log of this process goes back where the app keeps it
        EventLog.init(ApplicationProvider.getApplicationContext<Context>().filesDir)
    }

    private fun previousRun(vararg last: String) {
        val lines = listOf("01:00:00.000 [log] ---- process started ----") + (1..150).map { "01:00:01.000 [play] line $it" } + last
        File(dir, "sapoche.log").writeText(lines.joinToString("\n") + "\n")
    }

    @Test
    fun aCrashedRunComesWithTheCopiedLog() {
        previousRun("01:05:00.000 [crash] uncaught on main: java.lang.IllegalStateException: boom @ a.B.c:1")
        EventLog.init(dir)
        EventLog.d("play", "this run")
        assertTrue(EventLog.previousRunFailed)
        val copy = EventLog.snapshotForCopy()
        val cut = copy.indexOfFirst { it.startsWith("---- end of the previous run") }
        assertEquals("100 lines of the run that crashed, then the cut", 100, cut)
        assertTrue(copy[cut - 1].contains("[crash]"))
        assertTrue(copy.last().contains("this run"))
    }

    @Test
    fun aRunThatEndedWellAddsNothing() {
        previousRun("01:05:00.000 [log] stopped")
        EventLog.init(dir)
        assertFalse(EventLog.previousRunFailed)
        assertTrue(EventLog.snapshotForCopy().none { it.startsWith("---- end of the previous run") })
    }

    @Test
    fun aCrashOfAnEarlierRunDoesNotCount() {
        // The crash is older than the start of the last run, which ended well
        File(dir, "sapoche.log").writeText(
            "00:00:00.000 [crash] old\n01:00:00.000 [log] ---- process started ----\n01:00:01.000 [play] fine\n",
        )
        EventLog.init(dir)
        assertFalse(EventLog.previousRunFailed)
    }

    @Test
    fun noFileIsNoPreviousRun() {
        EventLog.init(dir)
        assertFalse(EventLog.previousRunFailed)
    }

    @Test
    fun theCrashHandlerLineNamesTheErrorAndWhereItWas() {
        val line = CrashLog.describe("main", IllegalStateException("boom", RuntimeException("root")))
        assertTrue(line, line.startsWith("uncaught on main: java.lang.IllegalStateException: boom caused by java.lang.RuntimeException: root @ "))
    }
}
