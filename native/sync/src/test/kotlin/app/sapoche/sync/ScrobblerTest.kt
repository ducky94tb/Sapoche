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
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class ScrobblerTest {

    private class Storage : ScrobbleStorage {
        override var token: String? = null
        var state: String? = null
        override fun loadState() = state
        override fun saveState(text: String) {
            state = text
        }
    }

    /** Answers from [replies] in turn (the last one for ever); one that is null is a failure to reach the service. */
    private class Http(val replies: MutableList<ScrobbleReply?> = mutableListOf()) : ScrobbleHttp {
        val asked = mutableListOf<Triple<String, String, String?>>()
        override suspend fun send(path: String, token: String, body: String?): ScrobbleReply {
            asked += Triple(path, token, body)
            val reply = if (replies.size > 1) replies.removeAt(0) else replies.firstOrNull()
            return reply ?: throw IOException("no network")
        }

        val submitted get() = asked.filter { it.first == "/1/submit-listens" }.map { Json.parseToJsonElement(it.third!!).jsonObject }
    }

    private val ok = ScrobbleReply(200, """{"status":"ok"}""")
    private val storage = Storage().apply { token = "tok" }
    private val http = Http(mutableListOf(ok))
    private val song = TrackRef("vid1", "Song (Official Video)", "Artist - Topic", null, 200_000)

    private fun TestScope.scrobbler(storage: Storage = this@ScrobblerTest.storage, http: Http = this@ScrobblerTest.http) = Scrobbler(
        storage, ListenBrainzService(http, "1.50.0"), this,
        namer = { SongNamesStub.title(it) to SongNamesStub.artist(it) },
        mono = { currentTime }, wall = { 1_700_000_000_000L + currentTime }, log = {},
    )

    private object SongNamesStub {
        fun title(t: TrackRef) = t.title.removeSuffix(" (Official Video)")
        fun artist(t: TrackRef) = t.artist.removeSuffix(" - Topic")
    }

    private fun Storage.pending(): Int = Json.parseToJsonElement(state!!).jsonObject["listens"]?.jsonArray?.size ?: 0

    @Test
    fun `the bodies are the same on every platform`() {
        val vectors = Json.parseToJsonElement(checkNotNull(javaClass.getResource("/scrobble_vectors.json")).readText()).jsonObject
        val version = vectors.getValue("version").jsonPrimitive.content
        for (case in vectors.getValue("cases").jsonArray.map { it.jsonObject }) {
            val listens = case.getValue("listens").jsonArray.map {
                val o = it.jsonObject
                Listen(
                    o.getValue("listenedAt").jsonPrimitive.content.toLong(), o.getValue("videoId").jsonPrimitive.content,
                    o.getValue("title").jsonPrimitive.content, o.getValue("artist").jsonPrimitive.content,
                    o.getValue("durationMs").jsonPrimitive.content.toLong(),
                )
            }
            val body = ListenBrainzService.body(case.getValue("type").jsonPrimitive.content, listens, version)
            assertEquals(case.getValue("body"), Json.parseToJsonElement(body), case.getValue("name").jsonPrimitive.content)
        }
    }

    @Test
    fun `without a token nothing is counted and nothing goes out`() = runTest {
        val storage = Storage()
        val scrobbler = scrobbler(storage)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(600_000)
        assertTrue(http.asked.isEmpty())
        assertNull(storage.state)
        assertFalse(scrobbler.status().connected)
    }

    @Test
    fun `a good token is kept with the name of its owner`() = runTest {
        val storage = Storage()
        http.replies[0] = ScrobbleReply(200, """{"code":200,"message":"Token valid.","valid":true,"user_name":"tvh"}""")
        val scrobbler = scrobbler(storage)
        assertEquals(ScrobbleConnect.OK, scrobbler.connect(" tok \n"))
        assertEquals("tok", storage.token)
        assertEquals("tvh", scrobbler.status().user)
        assertEquals("tok", http.asked[0].second)
    }

    @Test
    fun `a token that is not good is not kept, and no network is told apart`() = runTest {
        val storage = Storage()
        val scrobbler = scrobbler(storage)
        http.replies[0] = ScrobbleReply(200, """{"code":200,"message":"Token invalid.","valid":false}""")
        assertEquals(ScrobbleConnect.INVALID, scrobbler.connect("bad"))
        http.replies[0] = ScrobbleReply(401, """{"code":401}""")
        assertEquals(ScrobbleConnect.INVALID, scrobbler.connect("bad"))
        http.replies[0] = null
        assertEquals(ScrobbleConnect.OFFLINE, scrobbler.connect("tok"))
        http.replies[0] = ScrobbleReply(503)
        assertEquals(ScrobbleConnect.OFFLINE, scrobbler.connect("tok"))
        assertNull(storage.token)
    }

    @Test
    fun `a song is shown playing a few seconds in and sent once it counts, at the time it began`() = runTest {
        val scrobbler = scrobbler()
        advanceTimeBy(1_000)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(4_000)
        assertTrue(http.submitted.isEmpty(), "not yet: a song skipped at once must not show")
        advanceTimeBy(1_100)
        assertEquals("playing_now", http.submitted.single()["listen_type"]!!.jsonPrimitive.content)
        advanceTimeBy(95_000) // 100 s of playing: half the song
        val sent = http.submitted.last()
        assertEquals("single", sent["listen_type"]!!.jsonPrimitive.content)
        val listen = sent["payload"]!!.jsonArray.single().jsonObject
        assertEquals(1_700_000_001L, listen["listened_at"]!!.jsonPrimitive.content.toLong())
        val meta = listen["track_metadata"]!!.jsonObject
        assertEquals("Song", meta["track_name"]!!.jsonPrimitive.content)
        assertEquals("Artist", meta["artist_name"]!!.jsonPrimitive.content)
        assertEquals(0, scrobbler.status().pending)
        scrobbler.disconnect()
    }

    @Test
    fun `a song left before the mark is not sent, and a paused one does not count`() = runTest {
        val scrobbler = scrobbler()
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(60_000)
        scrobbler.watch(song, false, 200_000)
        advanceTimeBy(600_000)
        scrobbler.watch(null, false, 0)
        assertTrue(http.submitted.none { it["listen_type"]!!.jsonPrimitive.content != "playing_now" })
        assertEquals(0, scrobbler.status().pending)
    }

    @Test
    fun `playing now is left out when the person does not want it`() = runTest {
        val scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(20_000)
        assertTrue(http.submitted.isEmpty())
        scrobbler.disconnect()
    }

    @Test
    fun `with no network the listens wait on the phone and go together when it is back`() = runTest {
        http.replies.clear()
        http.replies += null
        val scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(100_000)
        scrobbler.watch(TrackRef("vid2", "Two", "B", null, 100_000), true, 100_000)
        advanceTimeBy(50_000)
        scrobbler.watch(null, false, 0)
        assertEquals(2, scrobbler.status().pending)
        assertEquals(2, storage.pending(), "kept on the phone")
        http.replies.clear()
        http.replies += ok
        advanceTimeBy(5 * 60_000)
        assertEquals(0, scrobbler.status().pending)
        val sent = http.submitted.last()
        assertEquals("import", sent["listen_type"]!!.jsonPrimitive.content)
        assertEquals(2, sent["payload"]!!.jsonArray.size)
        scrobbler.disconnect()
    }

    @Test
    fun `what waited when the app was closed is sent when it opens`() = runTest {
        // The state as a closed app left it
        storage.token = "tok"
        storage.state = """{"listens":[{"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000}]}"""
        http.replies[0] = ok
        val second = scrobbler()
        assertEquals(1, second.status().pending)
        second.resume()
        advanceTimeBy(1)
        assertEquals(0, second.status().pending)
        assertEquals(1, http.submitted.size)
    }

    @Test
    fun `a busy service is waited for as long as it says`() = runTest {
        http.replies.clear()
        http.replies += ScrobbleReply(429, "", resetInSec = 30)
        http.replies += ok
        val scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(100_100)
        assertEquals(1, http.submitted.size)
        advanceTimeBy(30_000)
        assertEquals(1, http.submitted.size, "31 s: not before it said")
        advanceTimeBy(2_000)
        assertEquals(2, http.submitted.size)
        assertEquals(0, scrobbler.status().pending)
        scrobbler.disconnect()
    }

    @Test
    fun `a token that is refused stops it and asks to connect again, keeping the listens`() = runTest {
        http.replies.clear()
        http.replies += ScrobbleReply(401)
        val scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(100_100)
        val status = scrobbler.status()
        assertTrue(status.reconnect)
        assertEquals(1, status.pending)
        advanceTimeBy(600_000)
        assertEquals(1, http.submitted.size, "no more asks with a token that is refused")
        scrobbler.watch(song, true, 200_000)
        assertEquals(1, http.submitted.size)
    }

    @Test
    fun `when the service refuses a batch the listens go one by one and only the bad one is dropped`() = runTest {
        storage.state = """{"listens":[
            {"listenedAt":1700000000,"videoId":"a","title":"A","artist":"B","durationMs":1000},
            {"listenedAt":1700000001,"videoId":"b","title":"","artist":"B","durationMs":1000},
            {"listenedAt":1700000002,"videoId":"c","title":"C","artist":"B","durationMs":1000}]}"""
        http.replies.clear()
        http.replies += ScrobbleReply(400) // the batch
        http.replies += ok // a
        http.replies += ScrobbleReply(400) // b alone
        http.replies += ok // c
        val scrobbler = scrobbler()
        scrobbler.resume()
        advanceTimeBy(1)
        assertEquals(0, scrobbler.status().pending)
        assertEquals(listOf("import", "single", "single", "single"), http.submitted.map { it["listen_type"]!!.jsonPrimitive.content })
    }

    @Test
    fun `disconnecting forgets the token and the queue and stops everything`() = runTest {
        http.replies[0] = null
        val scrobbler = scrobbler()
        scrobbler.setNowPlaying(false)
        scrobbler.watch(song, true, 200_000)
        advanceTimeBy(100_100)
        assertEquals(1, scrobbler.status().pending)
        scrobbler.disconnect()
        assertNull(storage.token)
        assertEquals(0, storage.pending())
        val asks = http.asked.size
        advanceTimeBy(600_000)
        assertEquals(asks, http.asked.size)
    }

    @Test
    fun `listens older than two weeks and beyond a thousand are dropped`() = runTest {
        val now = 1_700_000_000L
        val old = (1..3).joinToString(",") { """{"listenedAt":${now - 15 * 24 * 3600 + it},"videoId":"o$it","title":"T","artist":"A","durationMs":1}""" }
        val recent = (1..1_005).joinToString(",") { """{"listenedAt":${now - it},"videoId":"r$it","title":"T","artist":"A","durationMs":1}""" }
        storage.state = """{"listens":[$old,$recent]}"""
        http.replies[0] = null
        val scrobbler = scrobbler()
        assertEquals(1000, scrobbler.status().pending)
    }
}
