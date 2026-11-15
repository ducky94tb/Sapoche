package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VideoManifestTest {
    private fun source(itag: Int, height: Int, format: String, codec: String, kbps: Int, fps: Int = 30, ranges: Boolean = true) = VideoSource(
        url = "https://v/$itag", height = height, format = format, codec = codec, bitrateKbps = kbps, contentLength = 1L, itag = itag,
        width = height * 16 / 9, fps = fps,
        initRange = if (ranges) ByteRange(0, 741) else null,
        indexRange = if (ranges) ByteRange(742, 1229) else null,
    )

    private val h264 = source(137, 1080, "MPEG_4", "avc1.640028", 4334)
    private val h264Small = source(134, 360, "MPEG_4", "avc1.4D401E", 450)
    private val vp9 = source(271, 1440, "WEBM", "vp09.00.50.08", 8978, fps = 60)

    @Test
    fun `one adaptation set for every stream, each with its container, address and byte ranges`() {
        val mpd = VideoManifest.dash(listOf(h264, vp9, h264Small), 213_040) { "sapochev:abc/${it.itag}" }!!
        assertTrue("""mediaPresentationDuration="PT213.040S"""" in mpd)
        assertEquals(1, Regex("<AdaptationSet ").findAll(mpd).count(), "moving between them is inside one set")
        assertTrue("""<Representation id="271" mimeType="video/webm" codecs="vp09.00.50.08" bandwidth="8978000" width="2560" height="1440" frameRate="60">""" in mpd)
        assertTrue("""<Representation id="137" mimeType="video/mp4" codecs="avc1.640028" """ in mpd)
        assertTrue("<BaseURL>sapochev:abc/137</BaseURL>" in mpd)
        assertTrue("""<SegmentBase indexRange="742-1229"><Initialization range="0-741"/></SegmentBase>""" in mpd)
        assertTrue(mpd.indexOf("""id="134"""") < mpd.indexOf("""id="137"""") && mpd.indexOf("""id="137"""") < mpd.indexOf("""id="271""""), "lowest first")
    }

    @Test
    fun `a stream that does not tell its ranges is left out, and none left means no manifest`() {
        val blind = source(18, 360, "MPEG_4", "avc1.42001E", 500, ranges = false)
        assertFalse("""id="18"""" in VideoManifest.dash(listOf(h264, blind), 1000) { "x:${it.itag}" }!!)
        assertNull(VideoManifest.dash(listOf(blind), 1000) { "x" })
        assertNull(VideoManifest.dash(emptyList(), 1000) { "x" })
    }

    @Test
    fun `text in an address is escaped`() {
        val mpd = VideoManifest.dash(listOf(h264), 1000) { "a&b" }!!
        assertTrue("<BaseURL>a&amp;b</BaseURL>" in mpd)
    }

    @Test
    fun `the answer of the player request gives the ranges, the width and the rate`() {
        val json = kotlinx.serialization.json.Json.parseToJsonElement(
            this::class.java.getResource("/player/player_visionos.json")!!.readText(),
        )
        val videos = InnertubePlayer.parse(json, "dQw4w9WgXcQ").videos
        val big = videos.first { it.itag == 313 }
        assertEquals(ByteRange(0, 220), big.initRange)
        assertEquals(ByteRange(221, 893), big.indexRange)
        assertEquals(3840, big.width)
        assertTrue(videos.all { it.initRange != null && it.indexRange != null })
    }
}
