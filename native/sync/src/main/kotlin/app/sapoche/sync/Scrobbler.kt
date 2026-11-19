package app.sapoche.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** One song heard, as it is sent: [listenedAt] is when it began (seconds since 1970), the names are the cleaned ones. */
@Serializable
data class Listen(
    val listenedAt: Long,
    val videoId: String,
    val title: String,
    val artist: String,
    val durationMs: Long,
)

/** What the settings page shows: [pending] listens wait to be sent; [reconnect] says the token was refused and a new one is needed. */
data class ScrobbleStatus(val connected: Boolean, val user: String?, val nowPlaying: Boolean, val pending: Int, val reconnect: Boolean)

/** How the service answered: its [status], and with a 429 how many seconds until it takes the next ask ([resetInSec]). */
class ScrobbleReply(val status: Int, val body: String = "", val resetInSec: Int? = null)

/** Asks the service: [get] when [body] is null, else a POST of it. Throws an `IOException` when there is no network. */
fun interface ScrobbleHttp {
    suspend fun send(path: String, token: String, body: String?): ScrobbleReply
}

/** Where the token and the rest are kept; the token apart, so the platform can put it somewhere safer than the queue. */
interface ScrobbleStorage {
    var token: String?
    fun loadState(): String?
    fun saveState(text: String)
}

enum class ScrobbleConnect { OK, INVALID, OFFLINE }

/**
 * Sends what this phone plays to [ListenBrainz](https://listenbrainz.org), once the person has pasted a token of theirs.
 * Without a token it does nothing, and nothing goes out.
 *
 * It follows the player through [watch]: a song counts after half of it or four minutes, whichever is first, and never
 * when it is thirty seconds or less (the rule of ListenBrainz and Last.fm, stricter than the history's, so it has a
 * tracker of its own). A song that counts is written to a queue kept on the phone and sent at once; with no network, or
 * when the service is busy, it stays there and is sent later, many at a time, for 14 days or 1000 listens.
 * "Playing now" goes out a few seconds after a song starts, if the person wants it. Only the song goes out: nothing of
 * the room, its members or who added the song.
 *
 * [scope] must run on the thread that calls [watch] (the main one on Android), because the tracker is not thread safe.
 * Dart and Swift counterparts: `scrobbler.dart`, `Scrobbler.swift`.
 */
class Scrobbler(
    private val storage: ScrobbleStorage,
    private val http: ScrobbleHttp,
    private val scope: CoroutineScope,
    /** The title and the artist to send for a song: the cleaned names. */
    private val namer: (TrackRef) -> Pair<String, String>,
    private val version: String,
    private val mono: () -> Long,
    private val wall: () -> Long,
    private val log: (String) -> Unit = {},
) {
    @Serializable
    private class Saved(
        val user: String? = null,
        val nowPlaying: Boolean = true,
        val reconnect: Boolean = false,
        val listens: List<Listen> = emptyList(),
    )

    private val json = Json { ignoreUnknownKeys = true }
    private var user: String?
    private var nowPlaying: Boolean
    private var reconnect: Boolean
    private val listens: MutableList<Listen>

    init {
        val saved = storage.loadState()?.let { runCatching { json.decodeFromString<Saved>(it) }.getOrNull() } ?: Saved()
        user = saved.user
        nowPlaying = saved.nowPlaying
        reconnect = saved.reconnect
        listens = saved.listens.toMutableList()
        trim()
    }

    private val tracker = ListenTracker(heardAfterMs = HEARD_MS, minDurationMs = MIN_SONG_MS) { id, durationMs -> heard(id, durationMs) }
    private var current: TrackRef? = null
    private var startedAt: Long? = null
    private var lastDurationMs = 0L
    private var due: Job? = null
    private var announce: Job? = null
    private var sender: Job? = null

    private val connected get() = storage.token != null

    fun status() = ScrobbleStatus(connected, user, nowPlaying, listens.size, reconnect)

    /** Checks the token with the service and, if it is good, keeps it and sends what waits. */
    suspend fun connect(token: String): ScrobbleConnect {
        val clean = token.trim()
        val reply = try {
            http.send("/1/validate-token", clean, null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return ScrobbleConnect.OFFLINE
        }
        if (reply.status >= 500 || reply.status == 429) return ScrobbleConnect.OFFLINE
        val answer = runCatching { json.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
        val name = answer?.get("user_name")?.jsonPrimitive?.contentOrNull
        if (reply.status != 200 || answer?.get("valid")?.jsonPrimitive?.booleanOrNull != true || name.isNullOrEmpty()) return ScrobbleConnect.INVALID
        storage.token = clean
        user = name
        reconnect = false
        save()
        log("scrobble: connected as $name")
        send()
        return ScrobbleConnect.OK
    }

    /** Forgets the token and drops what had not been sent. */
    fun disconnect() {
        storage.token = null
        user = null
        reconnect = false
        listens.clear()
        save()
        reset()
        log("scrobble: disconnected")
    }

    fun setNowPlaying(on: Boolean) {
        nowPlaying = on
        if (!on) announce?.cancel()
        save()
    }

    /** The app is open: sends what waited while it was not. */
    fun resume() = send()

    /**
     * The player's state: the song it has loaded (null for none), whether it plays, and its length. Called at every
     * change of it, and cheap when nothing is connected.
     */
    fun watch(track: TrackRef?, playing: Boolean, durationMs: Long) {
        if (!connected || reconnect) {
            if (current != null) reset()
            return
        }
        val now = mono()
        if (track?.videoId != current?.videoId) {
            // Counts the song that is ending, if it just passed the mark, so `current` still has to be that one
            tracker.begin(track?.videoId, durationMs.coerceAtLeast(0), now)
            current = track
            startedAt = null
            announce?.cancel()
        }
        val song = current ?: return
        lastDurationMs = durationMs.coerceAtLeast(0)
        tracker.setDuration(lastDurationMs)
        tracker.setPlaying(playing, now)
        if (playing && startedAt == null) {
            startedAt = wall()
            if (nowPlaying) announce(song)
        }
        schedule()
    }

    private fun reset() {
        // Before the tracker is told, so that a song it counts on its way out is not queued
        current = null
        tracker.begin(null, 0, mono())
        startedAt = null
        due?.cancel()
        announce?.cancel()
        sender?.cancel()
    }

    private fun schedule() {
        due?.cancel()
        val wait = tracker.msUntilHeard(mono()) ?: return
        due = scope.launch {
            delay(wait)
            tracker.check(mono())
            schedule()
        }
    }

    private fun heard(id: String, durationMs: Long) {
        val song = current?.takeIf { it.videoId == id } ?: return
        val (title, artist) = namer(song)
        listens += Listen(
            (startedAt ?: wall()) / 1000, id, title, artist,
            if (durationMs > 0) durationMs else song.durMs,
        )
        trim()
        save()
        log("scrobble: '$title' queued (${listens.size} waiting)")
        send()
    }

    /** Tells the service what plays, a few seconds in, so a song that is skipped at once is not shown. */
    private fun announce(song: TrackRef) {
        announce?.cancel()
        announce = scope.launch {
            delay(ANNOUNCE_DELAY_MS)
            val token = storage.token ?: return@launch
            val (title, artist) = namer(song)
            val duration = if (lastDurationMs > 0) lastDurationMs else song.durMs
            try {
                http.send(SUBMIT, token, body("playing_now", listOf(Listen(0, song.videoId, title, artist, duration)), version))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log("scrobble: playing now not sent: ${e.message}")
            }
        }
    }

    private fun trim() {
        val oldest = wall() / 1000 - MAX_AGE_SEC
        val before = listens.size
        listens.removeAll { it.listenedAt < oldest }
        while (listens.size > MAX_LISTENS) listens.removeAt(0)
        if (listens.size < before) log("scrobble: ${before - listens.size} old listens dropped")
    }

    private fun save() {
        storage.saveState(json.encodeToString(Saved.serializer(), Saved(user, nowPlaying, reconnect, listens.toList())))
    }

    /** Sends the queue, a batch at a time, until it is empty; goes on trying later while the service cannot be reached. */
    private fun send() {
        if (sender?.isActive == true || listens.isEmpty() || !connected || reconnect) return
        sender = scope.launch {
            var wait = RETRY_MIN_MS
            var size = BATCH
            while (listens.isNotEmpty()) {
                val token = storage.token ?: return@launch
                val batch = listens.take(size)
                val reply = try {
                    http.send(SUBMIT, token, body(if (batch.size == 1) "single" else "import", batch, version))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    null
                }
                when {
                    reply == null || reply.status >= 500 -> {
                        delay(wait)
                        wait = minOf(wait * 2, RETRY_MAX_MS)
                    }
                    reply.status == 200 -> {
                        repeat(batch.size) { listens.removeAt(0) }
                        save()
                        wait = RETRY_MIN_MS
                    }
                    reply.status == 429 -> delay((reply.resetInSec ?: 60) * 1000L + 1000)
                    reply.status == 401 -> {
                        reconnect = true
                        save()
                        log("scrobble: the token was refused")
                        return@launch
                    }
                    // The service refused something in it: one at a time (until the queue is empty) finds what, and only that is dropped
                    batch.size > 1 -> size = 1
                    else -> {
                        log("scrobble: '${batch[0].title}' refused (${reply.status}), dropped")
                        listens.removeAt(0)
                        save()
                    }
                }
            }
        }
    }

    companion object {
        /** The ask that submits [batch] as [type]: `single`, `import` or `playing_now` (which carries no time). */
        fun body(type: String, batch: List<Listen>, version: String): String = buildJsonObject {
            put("listen_type", type)
            put("payload", buildJsonArray { batch.forEach { add(payload(it, type != "playing_now", version)) } })
        }.toString()

        private fun payload(listen: Listen, withTime: Boolean, version: String) = buildJsonObject {
            if (withTime) put("listened_at", listen.listenedAt)
            put("track_metadata", buildJsonObject {
                put("artist_name", listen.artist)
                put("track_name", listen.title)
                put("additional_info", buildJsonObject {
                    put("media_player", "Sapoche")
                    put("submission_client", "Sapoche")
                    put("submission_client_version", version)
                    if (!listen.videoId.startsWith("local:")) {
                        put("music_service", "youtube.com")
                        put("origin_url", "https://music.youtube.com/watch?v=${listen.videoId}")
                    }
                    if (listen.durationMs > 0) put("duration_ms", listen.durationMs)
                })
            })
        }

        private const val SUBMIT = "/1/submit-listens"

        /** A song counts after this long of playing, or half of it when that is less. */
        const val HEARD_MS = 4 * 60_000L

        /** A song of this length or less never counts. */
        const val MIN_SONG_MS = 30_000L
        const val ANNOUNCE_DELAY_MS = 5_000L
        const val BATCH = 100
        const val MAX_LISTENS = 1000
        const val MAX_AGE_SEC = 14 * 24 * 3600L
        const val RETRY_MIN_MS = 15_000L
        const val RETRY_MAX_MS = 5 * 60_000L
    }
}
