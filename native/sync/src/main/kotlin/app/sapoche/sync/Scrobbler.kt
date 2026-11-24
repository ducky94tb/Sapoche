package app.sapoche.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

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

/**
 * Sends what this phone plays to one [service] ([ListenBrainz](https://listenbrainz.org) or [Last.fm](https://www.last.fm)),
 * once the person has connected it. There is one of these for each, with a queue and counter of its own, so that one that
 * fails does not hold the other. Without a connection it does nothing, and nothing goes out.
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
    private val service: ScrobbleService,
    private val scope: CoroutineScope,
    /** The title and the artist to send for a song: the cleaned names. */
    private val namer: (TrackRef) -> Pair<String, String>,
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

    /** Checks [secret] (the token the person gave) with the service and, if it is good, keeps what it gives and sends what waits. */
    suspend fun connect(secret: String): ScrobbleConnect {
        val login = service.check(secret)
        if (login.result != ScrobbleConnect.OK) return login.result
        storage.token = login.credential
        user = login.user
        reconnect = false
        save()
        log("scrobble: connected as ${login.user}")
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
                service.playingNow(token, Listen(0, song.videoId, title, artist, duration))
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
            var size = service.batch
            while (listens.isNotEmpty()) {
                val token = storage.token ?: return@launch
                val batch = listens.take(size)
                val sent = service.submit(token, batch)
                when (sent.kind) {
                    ScrobbleSent.RETRY -> {
                        delay(wait)
                        wait = minOf(wait * 2, RETRY_MAX_MS)
                    }
                    ScrobbleSent.SENT -> {
                        repeat(batch.size) { listens.removeAt(0) }
                        save()
                        wait = RETRY_MIN_MS
                    }
                    ScrobbleSent.WAIT -> delay(sent.waitSec * 1000L + 1000)
                    ScrobbleSent.REAUTH -> {
                        reconnect = true
                        save()
                        log("scrobble: the token was refused")
                        return@launch
                    }
                    // Stops here; the next listen, or the app opened again, tries once more
                    ScrobbleSent.SUSPENDED -> {
                        log("scrobble: the service takes nothing for now")
                        return@launch
                    }
                    // The service refused something in it: one at a time (until the queue is empty) finds what, and only that is dropped
                    ScrobbleSent.REFUSED -> if (batch.size > 1) {
                        size = 1
                    } else {
                        log("scrobble: '${batch[0].title}' refused, dropped")
                        listens.removeAt(0)
                        save()
                    }
                }
            }
        }
    }

    companion object {
        /** A song counts after this long of playing, or half of it when that is less. */
        const val HEARD_MS = 4 * 60_000L

        /** A song of this length or less never counts. */
        const val MIN_SONG_MS = 30_000L
        const val ANNOUNCE_DELAY_MS = 5_000L
        const val MAX_LISTENS = 1000
        const val MAX_AGE_SEC = 14 * 24 * 3600L
        const val RETRY_MIN_MS = 15_000L
        const val RETRY_MAX_MS = 5 * 60_000L
    }
}
