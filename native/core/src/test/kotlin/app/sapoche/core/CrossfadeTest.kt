package app.sapoche.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CrossfadeTest {

    /** The same table is in `CrossfadeTests.swift` and `crossfade_test.dart`: the three platforms fade by the same amount. */
    private class Row(val position: Long, val duration: Long, val seconds: Int, val fadeIn: Boolean, val fadeOut: Boolean, val level: Float)

    private val table = listOf(
        // 6 s: the start fades in over 3 s, the end out over 6 s
        Row(0, 200_000, 6, true, true, 0f),
        Row(750, 200_000, 6, true, true, 0.1464f),
        Row(1_500, 200_000, 6, true, true, 0.5f),
        Row(2_250, 200_000, 6, true, true, 0.8536f),
        Row(3_000, 200_000, 6, true, true, 1f),
        Row(100_000, 200_000, 6, true, true, 1f),
        Row(194_000, 200_000, 6, true, true, 1f),
        Row(195_500, 200_000, 6, true, true, 0.8536f),
        Row(197_000, 200_000, 6, true, true, 0.5f),
        Row(198_500, 200_000, 6, true, true, 0.1464f),
        Row(200_000, 200_000, 6, true, true, 0f),
        Row(201_000, 200_000, 6, true, true, 0f),
        // A song that did not come by itself starts at full, one with nothing after it ends at full
        Row(0, 200_000, 6, false, true, 1f),
        Row(200_000, 200_000, 6, true, false, 1f),
        // Off, and songs shorter than three times the fade
        Row(0, 200_000, 0, true, true, 1f),
        Row(0, 17_999, 6, true, true, 1f),
        Row(17_999, 17_999, 6, true, true, 1f),
        Row(0, 18_000, 6, true, true, 0f),
        // The shortest and the longest setting
        Row(500, 200_000, 1, true, true, 1f),
        Row(199_500, 200_000, 1, true, true, 0.5f),
        Row(6_000, 600_000, 12, true, true, 1f),
        Row(3_000, 600_000, 12, true, true, 0.5f),
    )

    @Test
    fun `the volume of a position follows the table`() {
        for (r in table) {
            assertEquals(r.level, Crossfade.ramp(r.position, r.duration, r.seconds, r.fadeIn, r.fadeOut), 0.0001f, "${r.position} of ${r.duration} ms, ${r.seconds} s")
        }
    }

    @Test
    fun `a seconds value out of range is no fade`() {
        assertFalse(Crossfade.applies(600_000, 0))
        assertFalse(Crossfade.applies(600_000, 13))
        assertTrue(Crossfade.applies(600_000, 12))
    }

    @Test
    fun `a song seen near its end ended by itself, one seen in the middle did not`() {
        assertTrue(Crossfade.endedItself(197_000, 200_000, 3_200))
        assertTrue(Crossfade.endedItself(100_000, 200_000, 100_500))
        assertFalse(Crossfade.endedItself(100_000, 200_000, 20_000))
        assertFalse(Crossfade.endedItself(0, 0, 5_000))
    }
}
