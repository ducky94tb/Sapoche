package app.sapoche.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EqTest {
    private val vectors: JsonObject =
        Json.parseToJsonElement(checkNotNull(javaClass.getResource("/eq_vectors.json")).readText()).jsonObject

    @Test
    fun `the coefficients are the ones Swift tests against`() {
        for (case in vectors["cases"]!!.jsonArray) {
            val c = case.jsonObject
            val rate = c["sampleRate"]!!.jsonPrimitive.int
            val gains = Eq.clean(c["gains"]!!.jsonArray.map { it.jsonPrimitive.int })
            val bands = c["bands"]!!.jsonArray
            val got = Eq.coefficients(rate, gains)
            assertEquals(c["preampDb"]!!.jsonPrimitive.double, Eq.preampDb(gains), 1e-9)
            for (i in 0 until Eq.BANDS) {
                val want = bands[i]
                if (want is JsonNull) {
                    assertNull(got[i], "band $i at $rate Hz, gains ${gains.toList()}")
                    continue
                }
                val w = (want as JsonArray).map { it.jsonPrimitive.double }
                val g = got[i]!!
                assertEquals(w[0], g.b0, 1e-7)
                assertEquals(w[1], g.b1, 1e-7)
                assertEquals(w[2], g.b2, 1e-7)
                assertEquals(w[3], g.a1, 1e-7)
                assertEquals(w[4], g.a2, 1e-7)
            }
        }
    }

    @Test
    fun `gains are whole dB held to the range, missing ones are zero`() {
        assertContentEquals(intArrayOf(12, -12, 3, 0, 0, 0), Eq.clean(listOf(40, -40, 2.6)))
        assertContentEquals(IntArray(6), Eq.clean(null))
    }

    private fun sine(freq: Double, rate: Int, frames: Int, channels: Int = 1) = FloatArray(frames * channels) { i ->
        (0.25 * sin(2 * PI * freq * (i / channels) / rate)).toFloat()
    }

    /** The peak of the second half of the block (after the filters settled), of one channel. */
    private fun peak(samples: FloatArray, channels: Int = 1) =
        (samples.size / 2 until samples.size step channels).maxOf { abs(samples[it]) }

    private fun run(gains: IntArray, freq: Double, rate: Int = 44100): Pair<Float, Float> {
        val filter = EqFilter()
        filter.setGains(gains)
        filter.configure(rate, 1)
        val input = sine(freq, rate, rate)
        val output = input.copyOf()
        filter.process(output, output.size)
        return peak(input) to peak(output)
    }

    @Test
    fun `flat gains leave every sample as it was`() {
        val filter = EqFilter()
        filter.configure(44100, 2)
        val input = sine(1000.0, 44100, 4410, 2)
        val output = input.copyOf()
        assertFalse(filter.process(output, 4410))
        assertContentEquals(input, output)
        assertTrue(filter.isFlat)
    }

    @Test
    fun `a boost at 1 kHz is about 6 dB there and the preamp keeps the whole under full scale`() {
        val gains = intArrayOf(0, 0, 0, 6, 0, 0)
        // 6 dB up, then the preamp 6 dB down: at 1 kHz the sound is as loud as it was
        val (inPeak, outPeak) = run(gains, 1000.0)
        assertEquals(inPeak, outPeak, 0.01f)
        // far from the band the preamp is all there is: half
        val (lowIn, lowOut) = run(gains, 100.0)
        assertEquals(lowIn * 0.5f, lowOut, 0.02f)
        val (highIn, highOut) = run(gains, 15000.0)
        assertEquals(highIn * 0.5f, highOut, 0.02f)
    }

    @Test
    fun `the first band lifts the bass and the last lifts the treble`() {
        val (bassIn, bassOut) = run(intArrayOf(6, 0, 0, 0, 0, 0), 30.0)
        assertEquals(bassIn, bassOut, 0.02f)
        val (trebleIn, trebleOut) = run(intArrayOf(0, 0, 0, 0, 0, 6), 18000.0)
        assertEquals(trebleIn, trebleOut, 0.03f)
        // and a cut is a cut, with no preamp
        val (cutIn, cutOut) = run(intArrayOf(0, 0, 0, -12, 0, 0), 1000.0)
        assertEquals(cutIn * 0.25f, cutOut, 0.01f)
    }

    @Test
    fun `a loud song with the biggest boost stays under full scale`() {
        val rate = 44100
        val filter = EqFilter()
        filter.setGains(intArrayOf(12, 12, 6, 0, 0, 0))
        filter.configure(rate, 2)
        val loud = FloatArray(rate * 2) { i -> (0.99 * sin(2 * PI * 80.0 * (i / 2) / rate)).toFloat() }
        filter.process(loud, loud.size / 2)
        assertTrue(loud.all { abs(it) < 1f })
    }

    @Test
    fun `soft clip leaves small samples and never passes one`() {
        assertEquals(0.5f, Eq.softClip(0.5f))
        assertEquals(-0.9f, Eq.softClip(-0.9f))
        assertTrue(Eq.softClip(5f) <= 1f && Eq.softClip(5f) > 0.99f)
        assertEquals(-Eq.softClip(2f), Eq.softClip(-2f))
    }

    @Test
    fun `a change of gains while playing moves without a jump`() {
        val rate = 44100
        val filter = EqFilter()
        filter.configure(rate, 1)
        val first = sine(300.0, rate, rate)
        filter.process(first, first.size)
        filter.setGains(intArrayOf(12, 6, 0, 0, 0, 0))
        val next = sine(300.0, rate, 1024).also { for (i in it.indices) it[i] = (0.25 * sin(2 * PI * 300.0 * (rate + i) / rate)).toFloat() }
        val original = next.copyOf()
        filter.process(next, next.size)
        // the first sample is as it was (the move starts there), and no step between neighbours is larger than the signal's own
        assertEquals(original[0] * 1.0f, next[0], 0.01f)
        val ownStep = (1 until original.size).maxOf { abs(original[it] - original[it - 1]) }
        val step = (1 until next.size).maxOf { abs(next[it] - next[it - 1]) }
        assertTrue(step < ownStep * 2.5f, "step $step, own $ownStep")
    }

    @Test
    fun `back to flat the sound goes through untouched again`() {
        val filter = EqFilter()
        filter.setGains(intArrayOf(6, 0, 0, 0, 0, 0))
        filter.configure(44100, 1)
        val a = sine(200.0, 44100, 2048)
        filter.process(a, a.size)
        filter.setGains(IntArray(6))
        filter.process(a.copyOf(), a.size)
        val b = sine(200.0, 44100, 2048)
        val copy = b.copyOf()
        assertFalse(filter.process(b, b.size))
        assertContentEquals(copy, b)
    }

    @Test
    fun `a band beyond what the sample rate holds is left out`() {
        val got = Eq.coefficients(22050, intArrayOf(0, 0, 0, 0, 0, 6))
        assertNull(got[5])
    }
}
