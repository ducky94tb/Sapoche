package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals

class VideoLevelsTest {
    @Test
    fun `a film frame is named by its width, as YouTube names it`() {
        // The streams of https://music.youtube.com/watch?v=FN7ALfpGxiI, a 2.35:1 video: none has a standard height
        val real = listOf(3840 to 2026, 2560 to 1350, 1920 to 1012, 1280 to 676, 854 to 450, 640 to 338, 426 to 224, 256 to 136)
        assertEquals(listOf(2160, 1440, 1080, 720, 480, 360, 240, 144), real.map { (w, h) -> VideoLevels.nominalHeight(w, h) })
    }

    @Test
    fun `a standard picture keeps its height`() {
        assertEquals(1080, VideoLevels.nominalHeight(1920, 1080))
        assertEquals(720, VideoLevels.nominalHeight(1280, 720))
        assertEquals(360, VideoLevels.nominalHeight(640, 360))
        assertEquals(2160, VideoLevels.nominalHeight(3840, 2160))
    }

    @Test
    fun `a 4 to 3 or a square picture is named by its height, an upright one by its width`() {
        assertEquals(1080, VideoLevels.nominalHeight(1440, 1080))
        assertEquals(1080, VideoLevels.nominalHeight(1080, 1080))
        assertEquals(1080, VideoLevels.nominalHeight(1080, 1920))
        assertEquals(720, VideoLevels.nominalHeight(720, 1280))
    }

    @Test
    fun `without a width the height is taken to the nearest standard one`() {
        assertEquals(1080, VideoLevels.nominalHeight(0, 1012))
        assertEquals(360, VideoLevels.nominalHeight(0, 360))
    }

    @Test
    fun `the streams of a film frame video come out with the standard heights`() {
        val json = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"playabilityStatus":{"status":"OK"},"videoDetails":{"lengthSeconds":"278"},"streamingData":{"adaptiveFormats":[
               {"itag":251,"url":"https://example.invalid/a","mimeType":"audio/webm; codecs=\"opus\"","bitrate":130000},
               {"itag":137,"url":"https://example.invalid/v","mimeType":"video/mp4; codecs=\"avc1.640028\"","width":1920,"height":1012},
               {"itag":134,"url":"https://example.invalid/w","mimeType":"video/mp4; codecs=\"avc1.4D401E\"","width":640,"height":338}]}}""",
        )
        val videos = InnertubePlayer.parse(json, "FN7ALfpGxiI").videos
        assertEquals(listOf(1080, 360), videos.map { it.height })
        assertEquals(listOf(1920, 640), videos.map { it.width })
    }
}
