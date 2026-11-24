package app.sapoche.sync

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** How a connect went. [PENDING] is Last.fm only: the person has not yet allowed the app on its page. */
enum class ScrobbleConnect { OK, INVALID, PENDING, OFFLINE }

/** The answer of a connect: with [ScrobbleConnect.OK], whose account it is ([user]) and what to keep to send with ([credential]). */
class ScrobbleLogin(val result: ScrobbleConnect, val user: String? = null, val credential: String? = null)

/** How a send went; [waitSec] is only read with [WAIT]. */
enum class ScrobbleSent {
    SENT,

    /** Not reached, or the service is in trouble: try again later, with growing waits. */
    RETRY,

    /** Too often: wait [ScrobbleSend.waitSec] seconds. */
    WAIT,

    /** The credential is not good any more: the person has to connect again. */
    REAUTH,

    /** Something in it was refused: one listen at a time finds what. */
    REFUSED,

    /** Nothing more can be sent for now, and connecting again would not help (a key that was turned down, a wrong room key). */
    SUSPENDED,
}

class ScrobbleSend(val kind: ScrobbleSent, val waitSec: Int = 0)

/**
 * What differs between the places listens can be sent to; [Scrobbler] keeps what is the same (the counting, the queue, the
 * waits). A service throws only when it is cancelled: not being reached is an answer ([ScrobbleConnect.OFFLINE], [ScrobbleSent.RETRY]).
 * Dart and Swift counterparts: `scrobble_service.dart`, `ScrobbleService.swift`.
 */
interface ScrobbleService {
    /** The most listens one send takes. */
    val batch: Int

    /** Whether [secret], what the person gave (a token), makes a connection. */
    suspend fun check(secret: String): ScrobbleLogin

    suspend fun submit(credential: String, listens: List<Listen>): ScrobbleSend

    /** Tells what plays now. Throws an `IOException` when the service cannot be reached; the caller only logs it. */
    suspend fun playingNow(credential: String, listen: Listen)
}

/** [ListenBrainz](https://listenbrainz.org): the token the person pastes is the credential. */
class ListenBrainzService(private val http: ScrobbleHttp, private val version: String) : ScrobbleService {
    private val json = Json { ignoreUnknownKeys = true }

    override val batch get() = BATCH

    override suspend fun check(secret: String): ScrobbleLogin {
        val clean = secret.trim()
        val reply = try {
            http.send("/1/validate-token", clean, null)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return ScrobbleLogin(ScrobbleConnect.OFFLINE)
        }
        if (reply.status >= 500 || reply.status == 429) return ScrobbleLogin(ScrobbleConnect.OFFLINE)
        val answer = runCatching { json.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
        val name = answer?.get("user_name")?.jsonPrimitive?.contentOrNull
        if (reply.status != 200 || answer?.get("valid")?.jsonPrimitive?.booleanOrNull != true || name.isNullOrEmpty()) {
            return ScrobbleLogin(ScrobbleConnect.INVALID)
        }
        return ScrobbleLogin(ScrobbleConnect.OK, name, clean)
    }

    override suspend fun submit(credential: String, listens: List<Listen>): ScrobbleSend {
        val reply = try {
            http.send(SUBMIT, credential, body(if (listens.size == 1) "single" else "import", listens, version))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return ScrobbleSend(ScrobbleSent.RETRY)
        }
        return when {
            reply.status >= 500 -> ScrobbleSend(ScrobbleSent.RETRY)
            reply.status == 200 -> ScrobbleSend(ScrobbleSent.SENT)
            reply.status == 429 -> ScrobbleSend(ScrobbleSent.WAIT, reply.resetInSec ?: 60)
            reply.status == 401 -> ScrobbleSend(ScrobbleSent.REAUTH)
            else -> ScrobbleSend(ScrobbleSent.REFUSED)
        }
    }

    override suspend fun playingNow(credential: String, listen: Listen) {
        http.send(SUBMIT, credential, body("playing_now", listOf(listen), version))
    }

    companion object {
        const val BATCH = 100
        private const val SUBMIT = "/1/submit-listens"

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
    }
}

/** Asks Last.fm through the room server, which signs for the app (see `server/src/lastfm.ts`): [form] is the call, as a form. */
fun interface LastFmHttp {
    suspend fun send(form: String): ScrobbleReply
}

/**
 * [Last.fm](https://www.last.fm). The person is never asked for a password: [begin] gets a token and the page where it is
 * allowed, and once it is, [check] turns it into a session key, which is the credential. Every call goes to the room
 * server, so the app never holds the API key or its secret.
 */
class LastFmService(private val http: LastFmHttp, private val log: (String) -> Unit = {}) : ScrobbleService {
    private val json = Json { ignoreUnknownKeys = true }

    override val batch get() = BATCH

    /** The token to allow and the address where to allow it; null when the server has no Last.fm ([unavailable]) or cannot be reached. */
    class Begin(val token: String?, val url: String?, val unavailable: Boolean = false)

    suspend fun begin(): Begin {
        val reply = try {
            http.send(form(listOf("method" to "auth.getToken")))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return Begin(null, null)
        }
        if (reply.status == 503) return Begin(null, null, unavailable = true)
        val answer = runCatching { json.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
        val token = answer?.get("token")?.jsonPrimitive?.contentOrNull
        val url = answer?.get("url")?.jsonPrimitive?.contentOrNull
        return if (reply.status == 200 && !token.isNullOrEmpty() && !url.isNullOrEmpty()) Begin(token, url) else Begin(null, null)
    }

    override suspend fun check(secret: String): ScrobbleLogin {
        val reply = try {
            http.send(form(listOf("method" to "auth.getSession", "token" to secret.trim())))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return ScrobbleLogin(ScrobbleConnect.OFFLINE)
        }
        val answer = runCatching { json.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
        val session = answer?.get("session") as? JsonObject
        val key = session?.get("key")?.jsonPrimitive?.contentOrNull
        val name = session?.get("name")?.jsonPrimitive?.contentOrNull
        if (reply.status == 200 && !key.isNullOrEmpty() && !name.isNullOrEmpty()) return ScrobbleLogin(ScrobbleConnect.OK, name, key)
        return when (answer?.get("error")?.jsonPrimitive?.intOrNull) {
            14 -> ScrobbleLogin(ScrobbleConnect.PENDING)
            11, 16, 29 -> ScrobbleLogin(ScrobbleConnect.OFFLINE)
            null -> ScrobbleLogin(if (reply.status == 400 || reply.status == 403) ScrobbleConnect.INVALID else ScrobbleConnect.OFFLINE)
            else -> ScrobbleLogin(ScrobbleConnect.INVALID)
        }
    }

    override suspend fun submit(credential: String, listens: List<Listen>): ScrobbleSend {
        val reply = try {
            http.send(form(scrobbleParams(credential, listens)))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return ScrobbleSend(ScrobbleSent.RETRY)
        }
        val answer = runCatching { json.parseToJsonElement(reply.body) as? JsonObject }.getOrNull()
        val error = answer?.get("error")?.jsonPrimitive?.intOrNull
        if (error != null) {
            return when (error) {
                4, 9, 14, 15 -> ScrobbleSend(ScrobbleSent.REAUTH)
                26 -> ScrobbleSend(ScrobbleSent.SUSPENDED)
                29 -> ScrobbleSend(ScrobbleSent.WAIT, 60)
                11, 16 -> ScrobbleSend(ScrobbleSent.RETRY)
                else -> ScrobbleSend(ScrobbleSent.REFUSED)
            }
        }
        return when {
            // The room server did not take the call: its key is wrong, or it does not let this address ask so often
            reply.status == 401 -> ScrobbleSend(ScrobbleSent.SUSPENDED)
            reply.status == 429 -> ScrobbleSend(ScrobbleSent.WAIT, 60)
            reply.status != 200 -> ScrobbleSend(if (reply.status >= 500) ScrobbleSent.RETRY else ScrobbleSent.REFUSED)
            answer == null -> ScrobbleSend(ScrobbleSent.RETRY)
            else -> {
                val attr = (answer["scrobbles"] as? JsonObject)?.get("@attr") as? JsonObject
                val ignored = attr?.get("ignored")?.jsonPrimitive?.intOrNull ?: 0
                // A listen that Last.fm ignored is not sent again: it would be ignored again (too old, or over the day's limit)
                if (ignored > 0) log("scrobble: Last.fm ignored $ignored of ${listens.size}")
                ScrobbleSend(ScrobbleSent.SENT)
            }
        }
    }

    override suspend fun playingNow(credential: String, listen: Listen) {
        http.send(form(nowPlayingParams(credential, listen)))
    }

    companion object {
        const val BATCH = 50

        /** The parameters of `track.scrobble` for [listens]; the signature is the server's to add. */
        fun scrobbleParams(session: String, listens: List<Listen>): List<Pair<String, String>> = buildList {
            add("method" to "track.scrobble")
            add("sk" to session)
            listens.forEachIndexed { i, l ->
                add("artist[$i]" to l.artist)
                add("track[$i]" to l.title)
                add("timestamp[$i]" to l.listenedAt.toString())
                if (l.durationMs >= 1000) add("duration[$i]" to (l.durationMs / 1000).toString())
            }
        }

        /** The parameters of `track.updateNowPlaying`. */
        fun nowPlayingParams(session: String, listen: Listen): List<Pair<String, String>> = buildList {
            add("method" to "track.updateNowPlaying")
            add("sk" to session)
            add("artist" to listen.artist)
            add("track" to listen.title)
            if (listen.durationMs >= 1000) add("duration" to (listen.durationMs / 1000).toString())
        }

        /** [params] as a form, in the order of their names, every byte that is not a letter, a digit or `-._~` as `%XX`: the same text on every platform. */
        fun form(params: List<Pair<String, String>>): String =
            params.sortedBy { it.first }.joinToString("&") { (name, value) -> "${escape(name)}=${escape(value)}" }

        private fun escape(text: String): String = buildString {
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                if (c in 'A'.code..'Z'.code || c in 'a'.code..'z'.code || c in '0'.code..'9'.code || c == '-'.code || c == '.'.code || c == '_'.code || c == '~'.code) {
                    append(c.toChar())
                } else {
                    append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 15])
                }
            }
        }
    }
}
