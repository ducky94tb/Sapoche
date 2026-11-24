package app.sapoche.sync

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class LastFmServiceTest {

    /** Answers from [replies] in turn (the last one for ever); a null is a failure to reach the server. */
    private class Http(val replies: MutableList<ScrobbleReply?> = mutableListOf()) : LastFmHttp {
        val asked = mutableListOf<String>()
        override suspend fun send(form: String): ScrobbleReply {
            asked += form
            val reply = if (replies.size > 1) replies.removeAt(0) else replies.firstOrNull()
            return reply ?: throw IOException("no network")
        }
    }

    private class Storage : ScrobbleStorage {
        override var token: String? = null
        var state: String? = null
        override fun loadState() = state
        override fun saveState(text: String) {
            state = text
        }
    }

    private val http = Http()
    private val logged = mutableListOf<String>()
    private val service = LastFmService(http) { logged += it }
    private val one = listOf(Listen(1_700_000_000, "a", "A", "B", 200_000))

    private fun reply(status: Int, body: String) = ScrobbleReply(status, body)

    @Test
    fun `the forms are the same on every platform`() {
        val vectors = Json.parseToJsonElement(checkNotNull(javaClass.getResource("/lastfm_vectors.json")).readText()).jsonObject
        for (case in vectors.getValue("cases").jsonArray.map { it.jsonObject }) {
            val listens = case.getValue("listens").jsonArray.map {
                val o = it.jsonObject
                Listen(
                    o.getValue("listenedAt").jsonPrimitive.content.toLong(), o.getValue("videoId").jsonPrimitive.content,
                    o.getValue("title").jsonPrimitive.content, o.getValue("artist").jsonPrimitive.content,
                    o.getValue("durationMs").jsonPrimitive.content.toLong(),
                )
            }
            val session = case.getValue("session").jsonPrimitive.content
            val params = if (case.getValue("kind").jsonPrimitive.content == "scrobble") LastFmService.scrobbleParams(session, listens)
            else LastFmService.nowPlayingParams(session, listens[0])
            assertEquals(case.getValue("form").jsonPrimitive.content, LastFmService.form(params), case.getValue("name").jsonPrimitive.content)
        }
    }

    @Test
    fun `a token comes with the page that allows it`() = runTest {
        http.replies += reply(200, """{"token":"t1","url":"https://www.last.fm/api/auth/?api_key=k&token=t1"}""")
        val begin = service.begin()
        assertEquals("t1", begin.token)
        assertEquals("https://www.last.fm/api/auth/?api_key=k&token=t1", begin.url)
        assertEquals("method=auth.getToken", http.asked.single())
    }

    @Test
    fun `a server without Lastfm and one that cannot be reached are told apart`() = runTest {
        http.replies += reply(503, "Last.fm is not set up on this server")
        assertTrue(service.begin().unavailable)
        http.replies.clear()
        http.replies += null
        val offline = service.begin()
        assertNull(offline.token)
        assertTrue(!offline.unavailable)
    }

    @Test
    fun `the session comes once the person has allowed it`() = runTest {
        http.replies += reply(200, """{"session":{"name":"tvh","key":"sk-1","subscriber":0}}""")
        val login = service.check(" t1 ")
        assertEquals(ScrobbleConnect.OK, login.result)
        assertEquals("tvh", login.user)
        assertEquals("sk-1", login.credential)
        assertEquals("method=auth.getSession&token=t1", http.asked.single())
    }

    @Test
    fun `a token not yet allowed is pending, and one gone or unreachable is not`() = runTest {
        suspend fun check(r: ScrobbleReply?): ScrobbleConnect {
            http.replies.clear()
            http.replies += r
            return service.check("t").result
        }
        assertEquals(ScrobbleConnect.PENDING, check(reply(403, """{"error":14,"message":"Unauthorized Token - This token has not been authorized"}""")))
        assertEquals(ScrobbleConnect.INVALID, check(reply(403, """{"error":15,"message":"This token has expired"}""")))
        assertEquals(ScrobbleConnect.INVALID, check(reply(403, """{"error":4}""")))
        assertEquals(ScrobbleConnect.OFFLINE, check(reply(500, """{"error":16}""")))
        assertEquals(ScrobbleConnect.OFFLINE, check(reply(502, "Last.fm cannot be reached")))
        assertEquals(ScrobbleConnect.OFFLINE, check(reply(401, "Unauthorized")))
        assertEquals(ScrobbleConnect.OFFLINE, check(null))
    }

    @Test
    fun `the answers of a scrobble`() = runTest {
        suspend fun send(r: ScrobbleReply?): ScrobbleSend {
            http.replies.clear()
            http.replies += r
            return service.submit("sk", one)
        }
        assertEquals(ScrobbleSent.SENT, send(reply(200, """{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}""")).kind)
        assertEquals(ScrobbleSent.REAUTH, send(reply(403, """{"error":9,"message":"Invalid session key"}""")).kind)
        assertEquals(ScrobbleSent.SUSPENDED, send(reply(403, """{"error":26,"message":"Suspended API key"}""")).kind)
        val busy = send(reply(429, """{"error":29,"message":"Rate limit exceeded"}"""))
        assertEquals(ScrobbleSent.WAIT, busy.kind)
        assertEquals(60, busy.waitSec)
        assertEquals(ScrobbleSent.RETRY, send(reply(500, """{"error":16}""")).kind)
        assertEquals(ScrobbleSent.RETRY, send(reply(503, "")).kind)
        assertEquals(ScrobbleSent.REFUSED, send(reply(400, """{"error":6,"message":"Invalid parameters"}""")).kind)
        assertEquals(ScrobbleSent.REFUSED, send(reply(403, """{"error":13}""")).kind)
        assertEquals(ScrobbleSent.RETRY, send(null).kind)
        // The server of the room, not Last.fm
        assertEquals(ScrobbleSent.SUSPENDED, send(reply(401, "Unauthorized")).kind)
        assertEquals(ScrobbleSent.WAIT, send(reply(429, "Too many requests")).kind)
    }

    @Test
    fun `a listen that Lastfm ignored is counted as sent and logged`() = runTest {
        http.replies += reply(200, """{"scrobbles":{"@attr":{"accepted":0,"ignored":1},"scrobble":{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}}}""")
        assertEquals(ScrobbleSent.SENT, service.submit("sk", one).kind)
        assertTrue(logged.any { "ignored 1 of 1" in it }, logged.toString())
    }

    @Test
    fun `the queue of Lastfm goes in batches of fifty`() = runTest {
        val storage = Storage().apply { token = "sk" }
        storage.state = buildString {
            append("""{"listens":[""")
            append((0 until 120).joinToString(",") { """{"listenedAt":${1_700_000_000 + it},"videoId":"v$it","title":"T$it","artist":"A","durationMs":200000}""" })
            append("]}")
        }
        http.replies += reply(200, """{"scrobbles":{"@attr":{"accepted":50,"ignored":0}}}""")
        val scrobbler = lastFm(storage)
        scrobbler.resume()
        advanceTimeBy(1)
        assertEquals(0, scrobbler.status().pending)
        assertEquals(3, http.asked.size, "50, 50 and 20")
        assertEquals(50, Regex("""artist%5B\d+%5D=""").findAll(http.asked[0]).count())
        assertEquals(20, Regex("""artist%5B\d+%5D=""").findAll(http.asked[2]).count())
    }

    @Test
    fun `a session key that Lastfm refused stops it and keeps the listens`() = runTest {
        val storage = Storage().apply { token = "sk" }
        storage.state = """{"user":"tvh","listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000}]}"""
        http.replies += reply(403, """{"error":9,"message":"Invalid session key"}""")
        val scrobbler = lastFm(storage)
        scrobbler.resume()
        advanceTimeBy(1)
        assertTrue(scrobbler.status().reconnect)
        assertEquals(1, scrobbler.status().pending)
        assertEquals(1, http.asked.size)
    }

    @Test
    fun `a key that Lastfm suspended is tried again at the next opening, not before`() = runTest {
        val storage = Storage().apply { token = "sk" }
        storage.state = """{"user":"tvh","listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000}]}"""
        http.replies += reply(403, """{"error":26,"message":"Suspended API key"}""")
        val scrobbler = lastFm(storage)
        scrobbler.resume()
        advanceTimeBy(600_000)
        assertEquals(1, http.asked.size, "not in a loop")
        assertEquals(1, scrobbler.status().pending)
        assertTrue(!scrobbler.status().reconnect)
        http.replies.clear()
        http.replies += reply(200, """{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}""")
        scrobbler.resume()
        advanceTimeBy(1)
        assertEquals(0, scrobbler.status().pending)
    }

    private fun TestScope.lastFm(storage: Storage) = Scrobbler(
        storage, service, this,
        namer = { it.title to it.artist },
        mono = { currentTime }, wall = { 1_700_000_000_000L + currentTime }, log = {},
    )
}
