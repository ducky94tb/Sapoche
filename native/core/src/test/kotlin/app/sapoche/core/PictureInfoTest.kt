package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The same cases as `PictureInfoTests` of Swift, plus what only a phone that plays above 1080p can have. */
class PictureInfoTest {
    private val heights = listOf(144, 240, 360, 480, 720, 1080, 1440, 2160)

    @Test
    fun `nothing playing tells no limit`() {
        assertEquals(PictureInfo(), PictureInfo.of(emptyList(), 0, 1080, 1080, metered = false, budgetKbps = 0))
        assertNull(PictureInfo.of(heights, 0, 1080, 2160, metered = false, budgetKbps = 5000).limit)
    }

    @Test
    fun `the height asked for playing is no limit`() {
        val info = PictureInfo.of(heights, 720, 720, 2160, metered = false, budgetKbps = 5000)
        assertEquals(heights, info.heights)
        assertEquals(720, info.now)
        assertNull(info.limit)
    }

    @Test
    fun `a height below the one asked for because of the link is the network`() {
        assertEquals("network", PictureInfo.of(heights, 480, 1080, 2160, metered = false, budgetKbps = 900).limit)
        assertNull(PictureInfo.of(heights, 480, 1080, 2160, metered = false, budgetKbps = 0).limit, "nothing measured: not chosen for the link")
    }

    @Test
    fun `a song with nothing taller than it plays is the video, not the network`() {
        assertEquals("video", PictureInfo.of(listOf(144, 360, 720), 720, 1080, 2160, metered = false, budgetKbps = 5000).limit)
    }

    @Test
    fun `mobile data holds a picture asked above 1080p at 1080p and says so`() {
        assertEquals("metered", PictureInfo.of(heights, 1080, 2160, 2160, metered = true, budgetKbps = 5000).limit)
        assertNull(PictureInfo.of(heights, 1080, 1080, 2160, metered = true, budgetKbps = 5000).limit, "nothing above 1080p was asked")
        assertNull(PictureInfo.of(heights, 2160, 2160, 2160, metered = false, budgetKbps = 25000).limit)
        assertNull(PictureInfo.of(heights.filter { it <= 1080 }, 1080, 2160, 1080, metered = true, budgetKbps = 5000).limit, "this phone plays no more: nothing is lost to mobile data")
    }

    @Test
    fun `a phone that plays 1440p at most is not told of 2160p`() {
        assertNull(PictureInfo.of(heights.filter { it <= 1440 }, 1440, 2160, 1440, metered = false, budgetKbps = 25000).limit)
    }
}
