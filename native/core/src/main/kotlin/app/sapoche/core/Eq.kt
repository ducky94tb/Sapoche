package app.sapoche.core

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tanh

/**
 * The equalizer: six bands (see [FREQS]) from -12 to +12 dB. The first band is a low shelf, the last a high shelf, the
 * four between are peaking filters (the RBJ cookbook). Every band that is not at 0 is one biquad; the sound is turned
 * down by the largest boost first ([preampDb]) so that a boost cannot clip.
 *
 * The same numbers are in `Eq.swift` and in `eq_vectors.json`, which both test against.
 */
object Eq {
    const val BANDS = 6
    const val MAX_DB = 12

    val FREQS = intArrayOf(60, 150, 400, 1000, 2400, 15000)

    /** The share of the sample rate above which a band is left out (a filter near half the rate is not worth its noise). */
    private const val NYQUIST_SHARE = 0.45

    private const val PEAK_Q = 1.0
    private const val SHELF_Q = 0.7071

    /** One filter, divided by a0: y = b0 x + z1, z1 = b1 x - a1 y + z2, z2 = b2 x - a2 y. */
    class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double) {
        companion object {
            val IDENTITY = Biquad(1.0, 0.0, 0.0, 0.0, 0.0)
        }
    }

    /** [gains] as the six whole dB the player takes: the missing ones are 0, the others are held to the range. */
    fun clean(gains: List<Number>?): IntArray =
        IntArray(BANDS) { i -> (gains?.getOrNull(i)?.toDouble() ?: 0.0).let { Math.round(it).toInt().coerceIn(-MAX_DB, MAX_DB) } }

    fun isFlat(gains: IntArray): Boolean = gains.all { it == 0 }

    /** The gain (0 or below) that keeps the loudest boost from going past full scale. */
    fun preampDb(gains: IntArray): Double = -max(0, gains.maxOrNull() ?: 0).toDouble()

    /** The filters for [sampleRate]: one per band, null where the band is 0 dB or too near half the sample rate. */
    fun coefficients(sampleRate: Int, gains: IntArray): List<Biquad?> = List(BANDS) { i ->
        val gain = gains[i]
        val freq = FREQS[i]
        if (gain == 0 || freq >= sampleRate * NYQUIST_SHARE) null else biquad(sampleRate, i, gain)
    }

    private fun biquad(sampleRate: Int, band: Int, gainDb: Int): Biquad {
        val a = 10.0.pow(gainDb / 40.0)
        val w = 2 * PI * FREQS[band] / sampleRate
        val c = cos(w)
        val s = sin(w)
        val b0: Double
        val b1: Double
        val b2: Double
        val a0: Double
        val a1: Double
        val a2: Double
        if (band != 0 && band != BANDS - 1) {
            val alpha = s / (2 * PEAK_Q)
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a
        } else {
            val sq = 2 * sqrt(a) * (s / (2 * SHELF_Q))
            if (band == 0) {
                b0 = a * ((a + 1) - (a - 1) * c + sq); b1 = 2 * a * ((a - 1) - (a + 1) * c); b2 = a * ((a + 1) - (a - 1) * c - sq)
                a0 = (a + 1) + (a - 1) * c + sq; a1 = -2 * ((a - 1) + (a + 1) * c); a2 = (a + 1) + (a - 1) * c - sq
            } else {
                b0 = a * ((a + 1) + (a - 1) * c + sq); b1 = -2 * a * ((a - 1) + (a + 1) * c); b2 = a * ((a + 1) + (a - 1) * c - sq)
                a0 = (a + 1) - (a - 1) * c + sq; a1 = 2 * ((a - 1) - (a + 1) * c); a2 = (a + 1) - (a - 1) * c - sq
            }
        }
        return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    private const val KNEE = 0.9f

    /** Samples under 0.9 are left as they are; above it they bend toward 1 and never reach it. */
    fun softClip(x: Float): Float {
        val m = abs(x)
        if (m <= KNEE) return x
        val shaped = KNEE + (1 - KNEE) * tanh(((m - KNEE) / (1 - KNEE)).toDouble()).toFloat()
        return if (x < 0) -shaped else shaped
    }
}

/**
 * The filters of the equalizer over interleaved samples between -1 and 1. One thread calls [process] and [configure];
 * [setGains] may come from any thread. A change of the gains is spread over the next block (the coefficients move from
 * the old to the new in a straight line while the state of the filters goes on), so that it makes no click.
 */
class EqFilter {
    @Volatile
    private var wanted: IntArray = IntArray(Eq.BANDS)

    private var sampleRate = 0
    private var channels = 0
    private var applied: IntArray = IntArray(Eq.BANDS)
    private var from: List<Eq.Biquad?> = List(Eq.BANDS) { null }
    private var to: List<Eq.Biquad?> = List(Eq.BANDS) { null }
    private var preampFrom = 1.0
    private var preampTo = 1.0
    private var moving = false
    private var z1 = DoubleArray(0)
    private var z2 = DoubleArray(0)

    /** [gains] are six whole dB (see [Eq.clean]); the array is kept, so it is not changed after this. */
    fun setGains(gains: IntArray) {
        wanted = gains
    }

    /** Nothing is filtered: the sound goes through as it is. */
    val isFlat: Boolean get() = !moving && Eq.isFlat(applied) && Eq.isFlat(wanted)

    fun configure(sampleRate: Int, channels: Int) {
        this.sampleRate = sampleRate
        this.channels = channels
        z1 = DoubleArray(Eq.BANDS * channels)
        z2 = DoubleArray(Eq.BANDS * channels)
        applied = wanted
        to = Eq.coefficients(sampleRate, applied)
        from = to
        preampTo = 10.0.pow(Eq.preampDb(applied) / 20)
        preampFrom = preampTo
        moving = false
    }

    /** Filters [frames] frames in place; true when it changed any of them (false: the block is as it came). */
    fun process(samples: FloatArray, frames: Int): Boolean {
        val goal = wanted
        if (!goal.contentEquals(applied)) {
            // The filters as they stand now are where the move starts
            from = to
            preampFrom = preampTo
            applied = goal
            to = Eq.coefficients(sampleRate, goal)
            preampTo = 10.0.pow(Eq.preampDb(goal) / 20)
            moving = true
        }
        if (!moving && Eq.isFlat(applied)) {
            if (z1.any { it != 0.0 }) { z1.fill(0.0); z2.fill(0.0) }
            return false
        }
        val steady = !moving
        for (ch in 0 until channels) {
            for (i in 0 until frames) {
                val t = if (steady) 1.0 else (i + 1.0) / frames
                var x = samples[i * channels + ch].toDouble() * (preampFrom + (preampTo - preampFrom) * t)
                for (b in 0 until Eq.BANDS) {
                    val f = from[b]
                    val g = to[b]
                    if (f == null && g == null) continue
                    val k = b * channels + ch
                    val b0: Double
                    val b1: Double
                    val b2: Double
                    val a1: Double
                    val a2: Double
                    if (steady) {
                        g!!.let { b0 = it.b0; b1 = it.b1; b2 = it.b2; a1 = it.a1; a2 = it.a2 }
                    } else {
                        val p = f ?: Eq.Biquad.IDENTITY
                        val q = g ?: Eq.Biquad.IDENTITY
                        b0 = p.b0 + (q.b0 - p.b0) * t; b1 = p.b1 + (q.b1 - p.b1) * t; b2 = p.b2 + (q.b2 - p.b2) * t
                        a1 = p.a1 + (q.a1 - p.a1) * t; a2 = p.a2 + (q.a2 - p.a2) * t
                    }
                    val y = b0 * x + z1[k]
                    z1[k] = b1 * x - a1 * y + z2[k]
                    z2[k] = b2 * x - a2 * y
                    x = y
                }
                samples[i * channels + ch] = Eq.softClip(x.toFloat())
            }
        }
        if (moving) {
            moving = false
            from = to
            preampFrom = preampTo
        }
        return true
    }
}
