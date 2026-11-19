package app.sapoche

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * What kills the app leaves a line in [EventLog], where "Copy log" finds it: a crash that no one saw, an ANR, the system
 * ending the process for memory. Nothing leaves the phone.
 */
object CrashLog {
    private const val PREFS = "sapoche"
    private const val LAST_EXIT_SEEN = "last_exit_seen"
    private const val EXITS_ASKED = 5
    private const val STACK_FRAMES = 8

    /** Writes a line for an exception no one caught, makes sure it reaches the file, then lets the old handler go on. */
    fun install() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                EventLog.d("crash", describe(thread.name, error))
                EventLog.flush()
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun describe(threadName: String, error: Throwable): String {
        val frames = error.stackTrace.take(STACK_FRAMES).joinToString(" | ") { "${it.className}.${it.methodName}:${it.lineNumber}" }
        val cause = generateSequence(error.cause) { it.cause }.lastOrNull()?.let { " caused by ${it.javaClass.name}: ${it.message}" }.orEmpty()
        return "uncaught on $threadName: ${error.javaClass.name}: ${error.message}$cause @ $frames"
    }

    /**
     * From Android 11 the system keeps the last reasons the process ended: one `[exit]` line for each newer than the last
     * one seen. A crash or an ANR among them makes the log copied next carry the end of the run before this one.
     */
    fun readExits(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) readExitsFromR(context)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun readExitsFromR(context: Context) {
        runCatching {
            val manager = context.getSystemService(ActivityManager::class.java) ?: return
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val seen = prefs.getLong(LAST_EXIT_SEEN, 0L)
            val fresh = manager.getHistoricalProcessExitReasons(context.packageName, 0, EXITS_ASKED)
                .filter { it.timestamp > seen && it.reason != ApplicationExitInfo.REASON_USER_REQUESTED && it.reason != ApplicationExitInfo.REASON_EXIT_SELF }
            for (info in fresh.sortedBy { it.timestamp }) EventLog.d("exit", describe(info))
            if (fresh.any { it.reason in FAILURES }) EventLog.previousRunFailed = true
            fresh.maxOfOrNull { it.timestamp }?.let { prefs.edit().putLong(LAST_EXIT_SEEN, it).apply() }
        }
    }

    private val FAILURES = setOf(ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_ANR)

    @RequiresApi(Build.VERSION_CODES.R)
    private fun describe(info: ApplicationExitInfo): String {
        val at = java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date(info.timestamp))
        return "reason=${reasonName(info.reason)} importance=${info.importance} at=$at description=${info.description.orEmpty()}"
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun reasonName(reason: Int) = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        else -> "reason $reason"
    }
}
