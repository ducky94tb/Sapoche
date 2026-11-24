package app.sapoche

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.Diary
import app.sapoche.sync.LogLevel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/** The diary on disk: what a run that crashed leaves for the next one, and what "Log" reads back. */
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
        val lines = listOf("11-01 01:00:00.000 K [log] ---- process started ----") + (1..150).map { "11-01 01:00:01.000 I [play] line $it" } + last
        File(dir, "sapoche.log").writeText(lines.joinToString("\n") + "\n")
    }

    @Test
    fun aCrashedRunIsKnownAtTheNextStartAndItsLinesAreStillThere() {
        previousRun("11-01 01:05:00.000 E [crash] uncaught on main: java.lang.IllegalStateException: boom @ a.B.c:1")
        EventLog.init(dir)
        EventLog.d("play", "this run")
        assertTrue(EventLog.previousRunFailed)
        val lines = EventLog.lines()
        assertTrue(lines.any { it.contains("[crash]") })
        assertTrue(lines.any { it.contains("line 150") })
        assertTrue(lines.last().contains("this run"))
    }

    @Test
    fun aRunThatEndedWellIsNotAFailure() {
        previousRun("11-01 01:05:00.000 I [log] stopped")
        EventLog.init(dir)
        assertFalse(EventLog.previousRunFailed)
    }

    @Test
    fun aCrashOfAnEarlierRunDoesNotCount() {
        // The crash is older than the start of the last run, which ended well
        File(dir, "sapoche.log").writeText(
            "11-01 00:00:00.000 E [crash] old\n11-01 01:00:00.000 K [log] ---- process started ----\n11-01 01:00:01.000 I [play] fine\n",
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
    fun aLineHasTheSharedShapeAndTheLevelThatWasAsked() {
        EventLog.init(dir, "1.2.3+4")
        EventLog.w("room", "slow")
        EventLog.v("sync", "noise")
        val lines = EventLog.lines()
        assertTrue(lines.first().contains(" K [log] ---- process started ---- 1.2.3+4"))
        assertEquals(LogLevel.WARN, Diary.levelOf(lines.first { it.contains("slow") }))
        assertEquals(LogLevel.DETAIL, Diary.levelOf(lines.first { it.contains("noise") }))
    }

    @Test
    fun clearingLeavesOnlyTheNoteThatItHappened() {
        EventLog.init(dir)
        EventLog.d("play", "before")
        EventLog.clear()
        val lines = EventLog.lines()
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("the log was cleared"))
    }

    @Test
    fun theCrashHandlerLineNamesTheErrorAndWhereItWas() {
        val line = CrashLog.describe("main", IllegalStateException("boom", RuntimeException("root")))
        assertTrue(line, line.startsWith("uncaught on main: java.lang.IllegalStateException: boom caused by java.lang.RuntimeException: root @ "))
    }
}
