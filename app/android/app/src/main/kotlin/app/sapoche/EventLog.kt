package app.sapoche

import android.util.Log
import app.sapoche.sync.Diary
import app.sapoche.sync.DiaryFiles
import app.sapoche.sync.LogLevel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The diary of the app, mirrored to logcat and kept on disk (see [DiaryFiles]: two files that take every line, one that
 * takes the key lines alone). It is the file that "Log" in Settings reads, so a line is there after the app was killed,
 * and the full history can still be pulled over adb after a long screen-off test. Lines reach the file in batches, since
 * a write per line keeps the storage awake for nothing.
 */
object EventLog {
    private const val BATCH_LINES = 25
    private const val BATCH_MS = 60_000L
    const val STARTED = "---- process started ----"

    private val format = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)
    private var files: DiaryFiles? = null
    private val unwritten = ArrayList<String>()
    private var lastWriteMs = System.currentTimeMillis()

    /** The run before this one ended with a crash or an ANR (the line [CrashLog] wrote, or the system's word on it). */
    @Volatile
    var previousRunFailed = false

    fun init(dir: File, version: String = "") {
        // What is still waiting belongs to the folder it was written for, not to the one that starts now
        flush()
        val store = DiaryFiles(dir)
        files = store
        // A crash the handler saw wrote its own line (see CrashLog); the system's word on ANRs and kills comes later
        previousRunFailed = store.lastRun().takeLastWhile { !it.contains(STARTED) }.any { it.contains(" [crash] ") }
        k("log", "$STARTED${if (version.isEmpty()) "" else " $version"}")
    }

    /** A line whose level is worked out from its words (see [Diary.infer]); most callers use this. */
    fun d(tag: String, message: String) = add(null, tag, message)

    fun e(tag: String, message: String) = add(LogLevel.ERROR, tag, message)

    fun w(tag: String, message: String) = add(LogLevel.WARN, tag, message)

    /** A milestone: what someone reading a long log looks for first. */
    fun k(tag: String, message: String) = add(LogLevel.MAIN, tag, message)

    /** Noise: kept in the file, hidden in the viewer. */
    fun v(tag: String, message: String) = add(LogLevel.DETAIL, tag, message)

    @Synchronized
    private fun add(level: LogLevel?, tag: String, message: String) {
        val line = Diary.line(format.format(Date()), level ?: Diary.infer(tag, message), tag, message)
        Log.i("Sapoche", line)
        unwritten.add(line)
        if (unwritten.size >= BATCH_LINES || System.currentTimeMillis() - lastWriteMs > BATCH_MS) flush()
    }

    /** Writes what is waiting to the files; called when the app leaves the screen or the service ends, and for a crash. */
    @Synchronized
    fun flush() {
        if (unwritten.isNotEmpty()) runCatching { files?.append(unwritten) }
        unwritten.clear()
        lastWriteMs = System.currentTimeMillis()
    }

    /** Every line the files hold, oldest first (the end of a run that was killed is there too). */
    @Synchronized
    fun lines(): List<String> {
        flush()
        return files?.readAll().orEmpty()
    }

    @Synchronized
    fun clear() {
        unwritten.clear()
        files?.clear()
        k("log", "the log was cleared")
    }
}
