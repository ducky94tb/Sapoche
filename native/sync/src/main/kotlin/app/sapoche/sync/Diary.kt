package app.sapoche.sync

import java.io.File

/** How serious a line of the diary is. `E` and `W` and `K` (the main lines) are also kept in a small file of their own. */
enum class LogLevel(val letter: Char) {
    ERROR('E'),
    WARN('W'),

    /** A milestone: the app started, a room was joined, the song changed. */
    MAIN('K'),
    INFO('I'),

    /** Noise kept for the file and hidden in the viewer: a line every second, a request, an estimate. */
    DETAIL('D'),
    ;

    /** The line belongs to the small file that noise never pushes out. */
    val isKey: Boolean get() = this == ERROR || this == WARN || this == MAIN

    companion object {
        fun of(letter: Char): LogLevel? = entries.firstOrNull { it.letter == letter }
    }
}

/**
 * The shared shape of a line of the diary: `MM-dd HH:mm:ss.SSS L [tag] message`, the same on Android, iOS and the web
 * (`app/lib/data/log_line.dart`, `Core/Diary.swift`). The level is picked where the line is written: callers that know say it,
 * the others get [infer], which every side reads from `diary_levels.json`.
 */
object Diary {
    private const val STAMP = "MM-dd HH:mm:ss.SSS"
    private val LETTER_AT = STAMP.length + 1

    fun line(stamp: String, level: LogLevel, tag: String, message: String) = "$stamp ${level.letter} [$tag] $message"

    /** The level written in [line], or null for a line of the old shape (`HH:mm:ss.SSS [tag] message`) or a stray one. */
    fun levelOf(line: String): LogLevel? {
        if (line.length <= LETTER_AT + 3 || line[LETTER_AT + 1] != ' ' || line[LETTER_AT + 2] != '[') return null
        if (line[2] != '-' || line[5] != ' ') return null
        return LogLevel.of(line[LETTER_AT])
    }

    private val DETAIL_TAGS = setOf("http")
    private val DETAIL_PREFIXES = listOf("drift=")
    private val DETAIL_PARTS = listOf("bandwidth estimate")
    private val ERROR_TAGS = setOf("crash", "error", "diagnostic")
    private val ERROR_PARTS = listOf("player error", "uncaught", "the player failed")
    private val WARN_PARTS = listOf(
        "failed", "could not", "giving up", "did not load", "weak network", "stalled", "no answer", "rejected", "refused",
        "reconnecting", "closed:", "server error", "unparsable", "found nothing", "no radio",
    )
    private val MAIN_PREFIXES = listOf(
        "connected to ", "listening on my own", "back to listening on my own", "following the room again", "advanced locally to",
        "following '", "prepared '", "---- process started", "the sound was taken", "the interruption", "the output changed", "the output went away",
    )

    /** The level of a line written without one. First match wins, from the loudest. */
    fun infer(tag: String, message: String): LogLevel {
        val text = message.lowercase()
        if (tag in DETAIL_TAGS || DETAIL_PREFIXES.any { text.startsWith(it) } || DETAIL_PARTS.any { it in text }) return LogLevel.DETAIL
        if (tag in ERROR_TAGS || ERROR_PARTS.any { it in text }) return LogLevel.ERROR
        if (tag == "exit") return if (Regex("reason=(CRASH|CRASH_NATIVE|ANR)").containsMatchIn(message)) LogLevel.ERROR else LogLevel.WARN
        if (WARN_PARTS.any { it in text }) return LogLevel.WARN
        if (MAIN_PREFIXES.any { text.startsWith(it) }) return LogLevel.MAIN
        return LogLevel.INFO
    }
}

/**
 * The diary on disk: `sapoche.log` and `sapoche.1.log` take every line, one after the other (when the first is full it
 * becomes the second and the old second is gone), and `sapoche-key.log` takes the key lines alone, so that a minute of
 * noise never pushes a failure out of reach. Not thread safe: [EventLog] and its mirrors hold the lock.
 */
class DiaryFiles(
    private val dir: File,
    private val maxBytes: Long = 1_000_000L,
    private val maxKeyBytes: Long = 256_000L,
) {
    private val current = File(dir, "sapoche.log")
    private val older = File(dir, "sapoche.1.log")
    private val key = File(dir, "sapoche-key.log")

    init {
        dir.mkdirs()
        // A file of the old shape (one file, no date, no level) is not worth reading beside the new ones
        if (current.exists() && !isNewShape(current)) current.delete()
    }

    fun append(lines: List<String>) {
        if (lines.isEmpty()) return
        val text = lines.joinToString("\n", postfix = "\n")
        if (current.exists() && current.length() + text.length > maxBytes) {
            older.delete()
            current.renameTo(older)
        }
        current.appendText(text)
        val keys = lines.filter { Diary.levelOf(it)?.isKey == true }
        if (keys.isNotEmpty()) {
            key.appendText(keys.joinToString("\n", postfix = "\n"))
            if (key.length() > maxKeyBytes) trimKey()
        }
    }

    /**
     * Every line there is, oldest first: the key lines that the full files no longer reach, then the full files. A key line
     * is in the full files too until they roll over it, so it is left out of the first part when it is there.
     */
    fun readAll(): List<String> {
        val full = listOf(older, current).flatMap { readLines(it) }
        val seen = HashSet<String>(full)
        return readLines(key).filter { it !in seen } + full
    }

    /** The lines of the file that holds the newest lines, from its end: [maxBytes] at most. */
    fun lastRun(maxBytes: Int = 64 * 1024): List<String> {
        if (!current.exists()) return emptyList()
        java.io.RandomAccessFile(current, "r").use { raf ->
            val from = maxOf(0L, raf.length() - maxBytes)
            raf.seek(from)
            val bytes = ByteArray((raf.length() - from).toInt()).also { raf.readFully(it) }
            val all = String(bytes, Charsets.UTF_8).lines().filter { it.isNotEmpty() }
            return if (from > 0) all.drop(1) else all
        }
    }

    fun clear() {
        current.delete()
        older.delete()
        key.delete()
    }

    private fun trimKey() {
        val all = readLines(key)
        key.writeText(all.drop(all.size / 2).joinToString("\n", postfix = "\n"))
    }

    private fun readLines(file: File): List<String> =
        if (file.exists()) runCatching { file.readLines().filter { it.isNotEmpty() } }.getOrDefault(emptyList()) else emptyList()

    private fun isNewShape(file: File): Boolean = runCatching { file.bufferedReader().use { it.readLine() } }.getOrNull()
        ?.let { Diary.levelOf(it) != null } ?: true
}
