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
 * What the player does reaches ListenBrainz: a player that says what is loaded and whether it plays, [ListenHistory]
 * watching it, the real [Scrobbler] and its storage, and a stand-in for the service.
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
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var storage: AndroidScrobbleStorage
    private lateinit var scrobbler: Scrobbler
    private lateinit var store: LibraryStore
    private lateinit var player: ScriptedPlayer
    private lateinit var history: ListenHistory

    private val song = MediaItem.Builder().setMediaId("dQw4w9WgXcQ")
        .setMediaMetadata(MediaMetadata.Builder().setTitle("Never Gonna Give You Up (Official Video)").setArtist("Rick Astley - Topic").build())
        .build()

    @Before
    fun start() {
        File(context.filesDir, "scrobble.json").delete()
        storage = AndroidScrobbleStorage(context).also { it.token = null }
        // The app does not speak plain HTTP, so the stand-in speaks HTTPS with a certificate only this test trusts
        val held = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(held).build().sslSocketFactory())
        val trusting = HandshakeCertificates.Builder().addTrustedCertificate(held.certificate).build()
        val client = OkHttpClient.Builder().sslSocketFactory(trusting.sslSocketFactory(), trusting.trustManager).build()
        server.start()
        store = LibraryStore(context, name = null)
        scrobbler = Scrobbler(
            storage, ListenBrainzHttp(client, server.url("/").toString().trimEnd('/')), scope,
            namer = { SongNames.title(it.title, it.artist) to SongNames.credit(it.artist) },
            version = "test", mono = SystemClock::elapsedRealtime, wall = System::currentTimeMillis,
        ) { android.util.Log.d("ScrobbleTest", it) }
        instrumentation.runOnMainSync {
            player = ScriptedPlayer()
            // Asking for anything makes it take the first state, so that a change after it is one that is told
            player.playbackState
            history = ListenHistory(player, store, scope, scrobbler = scrobbler) { android.util.Log.d("ScrobbleTest", "history: $it") }.also { it.start() }
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
        storage.token = null
        File(context.filesDir, "scrobble.json").delete()
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
}
