package app.sapoche

import android.content.Context
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import app.sapoche.core.SongNames
import app.sapoche.sync.ListenBrainzHttp
import app.sapoche.sync.LastFmService
import app.sapoche.sync.ListenBrainzService
import app.sapoche.sync.RoomLastFmHttp
import app.sapoche.sync.ScrobbleConnect
import app.sapoche.sync.Scrobbler
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import mockwebserver3.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * What the player does reaches ListenBrainz and Last.fm: a player that says what is loaded and whether it plays,
 * [ListenHistory] watching it, the real [Scrobbler]s and their storage, and a stand-in for each service (Last.fm is asked
 * through the room server, so its stand-in is that).
 */
@androidx.annotation.OptIn(UnstableApi::class)
class ScrobbleWiringTest {

    /** A player that plays only when told: no sound, no file, but the events of a real one. */
    private class ScriptedPlayer : SimpleBasePlayer(Looper.getMainLooper()) {
        private var item: MediaItem? = null
        private var durationMs = 0L
        private var playing = false

        fun load(item: MediaItem?, durationMs: Long, playing: Boolean) {
            this.item = item
            this.durationMs = durationMs
            this.playing = playing
            invalidateState()
        }

        override fun getState(): State {
            val builder = State.Builder().setAvailableCommands(Player.Commands.Builder().addAllCommands().build())
            item?.let {
                builder.setPlaylist(listOf(MediaItemData.Builder(it.mediaId).setMediaItem(it).setDurationUs(durationMs * 1000).build()))
                    .setPlaybackState(Player.STATE_READY)
                    .setPlayWhenReady(playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            }
            return builder.build()
        }

        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> = Futures.immediateVoidFuture()

        override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()
    }

    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val server = MockWebServer()
    private val lastFmServer = MockWebServer()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var storage: AndroidScrobbleStorage
    private lateinit var scrobbler: Scrobbler
    private lateinit var lastFmStorage: AndroidScrobbleStorage
    private lateinit var lastFm: Scrobbler
    private lateinit var store: LibraryStore
    private lateinit var player: ScriptedPlayer
    private lateinit var history: ListenHistory

    private val song = MediaItem.Builder().setMediaId("dQw4w9WgXcQ")
        .setMediaMetadata(MediaMetadata.Builder().setTitle("Never Gonna Give You Up (Official Video)").setArtist("Rick Astley - Topic").build())
        .build()

    @Before
    fun start() {
        File(context.filesDir, "scrobble.json").delete()
        File(context.filesDir, "scrobble-lastfm.json").delete()
        storage = AndroidScrobbleStorage(context).also { it.token = null }
        lastFmStorage = AndroidScrobbleStorage(context, "lastfm_session", "scrobble-lastfm.json").also { it.token = null }
        // The app does not speak plain HTTP, so the stand-in speaks HTTPS with a certificate only this test trusts
        val held = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val certificates = HandshakeCertificates.Builder().heldCertificate(held).build()
        server.useHttps(certificates.sslSocketFactory())
        lastFmServer.useHttps(certificates.sslSocketFactory())
        val trusting = HandshakeCertificates.Builder().addTrustedCertificate(held.certificate).build()
        val client = OkHttpClient.Builder().sslSocketFactory(trusting.sslSocketFactory(), trusting.trustManager).build()
        server.start()
        lastFmServer.start()
        store = LibraryStore(context, name = null)
        scrobbler = Scrobbler(
            storage, ListenBrainzService(ListenBrainzHttp(client, server.url("/").toString().trimEnd('/')), "test"), scope,
            namer = { SongNames.title(it.title, it.artist) to SongNames.credit(it.artist) },
            mono = SystemClock::elapsedRealtime, wall = System::currentTimeMillis,
        ) { android.util.Log.d("ScrobbleTest", it) }
        lastFm = Scrobbler(
            lastFmStorage,
            LastFmService(RoomLastFmHttp({ lastFmServer.url("/").toString().trimEnd('/') }, { mapOf("X-Sapoche-Key" to "room-key") }, client)),
            scope,
            namer = { SongNames.title(it.title, it.artist) to SongNames.credit(it.artist) },
            mono = SystemClock::elapsedRealtime, wall = System::currentTimeMillis,
        ) { android.util.Log.d("ScrobbleTest", "lastfm: $it") }
        instrumentation.runOnMainSync {
            player = ScriptedPlayer()
            // Asking for anything makes it take the first state, so that a change after it is one that is told
            player.playbackState
            history = ListenHistory(player, store, scope, scrobblers = listOf(scrobbler, lastFm)) { android.util.Log.d("ScrobbleTest", "history: $it") }.also { it.start() }
        }
    }

    @After
    fun stop() {
        instrumentation.runOnMainSync {
            history.stop()
            player.release()
        }
        scope.cancel()
        store.close()
        server.close()
        lastFmServer.close()
        storage.token = null
        lastFmStorage.token = null
        File(context.filesDir, "scrobble.json").delete()
        File(context.filesDir, "scrobble-lastfm.json").delete()
    }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun connect() {
        server.enqueue(MockResponse.Builder().code(200).body("""{"code":200,"valid":true,"user_name":"tester"}""").build())
        assertEquals(ScrobbleConnect.OK, runBlocking { scrobbler.connect("secret-token") })
        server.takeRequest(5, TimeUnit.SECONDS)
    }

    @Test
    fun aSongThatPlaysIsShownNowAndSentOnceItCounts() {
        connect()
        server.enqueue(MockResponse.Builder().code(200).body("""{"status":"ok"}""").build())
        server.enqueue(MockResponse.Builder().code(200).body("""{"status":"ok"}""").build())
        val before = System.currentTimeMillis() / 1000
        // 31 s long: it counts at half, 15.5 s of playing
        onMain { player.load(song, 31_000, playing = true) }

        val now = server.takeRequest(15, TimeUnit.SECONDS)
        assertNotNull("playing now was not sent", now)
        assertEquals("/1/submit-listens", now!!.url.encodedPath)
        assertEquals("Token secret-token", now.headers["Authorization"])
        val shown = Json.parseToJsonElement(now.body!!.utf8()).jsonObject
        assertEquals("playing_now", shown["listen_type"]!!.jsonPrimitive.content)
        val meta = shown["payload"]!!.jsonArray.single().jsonObject["track_metadata"]!!.jsonObject
        assertEquals("Never Gonna Give You Up", meta["track_name"]!!.jsonPrimitive.content)
        assertEquals("Rick Astley", meta["artist_name"]!!.jsonPrimitive.content)

        val listen = server.takeRequest(30, TimeUnit.SECONDS)
        assertNotNull("the listen was not sent", listen)
        val sent = Json.parseToJsonElement(listen!!.body!!.utf8()).jsonObject
        assertEquals("single", sent["listen_type"]!!.jsonPrimitive.content)
        val at = sent["payload"]!!.jsonArray.single().jsonObject["listened_at"]!!.jsonPrimitive.content.toLong()
        assertTrue("listened_at is when it began, not when it counted: $at", at in before..before + 2)
        // The answer is read after the service has been asked
        val until = SystemClock.elapsedRealtime() + 3_000
        while (scrobbler.status().pending > 0 && SystemClock.elapsedRealtime() < until) Thread.sleep(50)
        assertEquals(0, scrobbler.status().pending)
        // The queue file never holds the token
        assertTrue(!File(context.filesDir, "scrobble.json").readText().contains("secret-token"))
    }

    @Test
    fun aSongLeftAtOnceIsNeitherShownNorSent() {
        connect()
        onMain { player.load(song, 200_000, playing = true) }
        Thread.sleep(2_000)
        onMain { player.load(null, 0, playing = false) }
        assertNull(server.takeRequest(7, TimeUnit.SECONDS))
        assertEquals(0, scrobbler.status().pending)
    }

    @Test
    fun withNoTokenNothingGoesOutAtAll() {
        onMain { player.load(song, 31_000, playing = true) }
        assertNull(server.takeRequest(20, TimeUnit.SECONDS))
        assertEquals(0, server.requestCount)
        assertNull(storage.loadState())
    }

    @Test
    fun theServiceBeingAwayKeepsTheListenForLater() {
        connect()
        server.enqueue(MockResponse.Builder().code(503).build())
        scrobbler.setNowPlaying(false)
        onMain { player.load(song, 31_000, playing = true) }
        assertNotNull("the listen was not tried", server.takeRequest(30, TimeUnit.SECONDS))
        // Refused with a 503: it waits on the phone, kept in the file
        Thread.sleep(500)
        assertEquals(1, scrobbler.status().pending)
        assertTrue(File(context.filesDir, "scrobble.json").readText().contains("dQw4w9WgXcQ"))
    }

    @Test
    fun lastFmGetsTheSameSongOnItsOwnAndThroughTheRoomServer() {
        connect()
        lastFmServer.enqueue(MockResponse.Builder().code(200).body("""{"session":{"name":"fmtester","key":"sk-secret","subscriber":0}}""").build())
        assertEquals(ScrobbleConnect.OK, runBlocking { lastFm.connect("allowed-token") })
        val login = lastFmServer.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/lastfm", login.url.encodedPath)
        assertEquals("room-key", login.headers["X-Sapoche-Key"])
        assertEquals("method=auth.getSession&token=allowed-token", login.body!!.utf8())

        server.enqueue(MockResponse.Builder().code(200).body("""{"status":"ok"}""").build())
        server.enqueue(MockResponse.Builder().code(200).body("""{"status":"ok"}""").build())
        lastFmServer.enqueue(MockResponse.Builder().code(200).body("""{"nowplaying":{}}""").build())
        lastFmServer.enqueue(MockResponse.Builder().code(200).body("""{"scrobbles":{"@attr":{"accepted":1,"ignored":0}}}""").build())
        onMain { player.load(song, 31_000, playing = true) }

        val now = lastFmServer.takeRequest(15, TimeUnit.SECONDS)
        assertNotNull("playing now was not sent to Last.fm", now)
        assertTrue(now!!.body!!.utf8(), "method=track.updateNowPlaying" in now.body!!.utf8() && "sk=sk-secret" in now.body!!.utf8())
        val listen = lastFmServer.takeRequest(30, TimeUnit.SECONDS)
        assertNotNull("the listen was not sent to Last.fm", listen)
        val form = listen!!.body!!.utf8()
        assertTrue(form, "method=track.scrobble" in form && "artist%5B0%5D=Rick%20Astley" in form && "track%5B0%5D=Never%20Gonna%20Give%20You%20Up" in form)
        // ListenBrainz went on in parallel with what it had
        assertNotNull(server.takeRequest(15, TimeUnit.SECONDS))
        assertNotNull(server.takeRequest(30, TimeUnit.SECONDS))
        val until = SystemClock.elapsedRealtime() + 3_000
        while ((lastFm.status().pending > 0 || scrobbler.status().pending > 0) && SystemClock.elapsedRealtime() < until) Thread.sleep(50)
        assertEquals(0, lastFm.status().pending)
        assertEquals(0, scrobbler.status().pending)
        // Neither the session key nor the token of the connect is in the queue file
        val file = File(context.filesDir, "scrobble-lastfm.json").readText()
        assertTrue(!file.contains("sk-secret") && !file.contains("allowed-token"))
    }
}
