package app.sapoche.core

import kotlin.math.PI
import kotlin.math.sin

/**
 * The soft change between two songs: the last seconds of a song fade out and the first half of that time of the next
 * song fades in. The songs do not overlap, so no moment of the room's timeline moves and the gapless change stays.
 *
 * Only the volume is a function of the position; whether a fade applies at the start (the song came by itself, not by a
 * press on Next) and at the end (a song follows) is for the player's side to say.
 */
object Crossfade {
    const val MAX_SECONDS = 12

    /** A song shorter than this many times the fade time is played as it is. */
    private const val MIN_SONG_FACTOR = 3

    /** The fade is on for songs of this length. */
    fun applies(durationMs: Long, seconds: Int): Boolean =
        seconds in 1..MAX_SECONDS && durationMs >= MIN_SONG_FACTOR * seconds * 1000L

    /** The share (0..1) of the volume that [positionMs] of a song [durationMs] long gets; 1 outside the two fades. */
    fun ramp(positionMs: Long, durationMs: Long, seconds: Int, fadeIn: Boolean, fadeOut: Boolean): Float {
        if (!applies(durationMs, seconds)) return 1f
        val outMs = seconds * 1000L
        val inMs = outMs / 2
        var level = 1f
        if (fadeOut && durationMs - positionMs < outMs) level *= curve((durationMs - positionMs).coerceAtLeast(0) / outMs.toFloat())
        if (fadeIn && positionMs < inMs) level *= curve(positionMs.coerceAtLeast(0) / inMs.toFloat())
        return level
    }

    /** Whether a song that was last seen playing at [lastPositionMs], [elapsedMs] ago, has played to its end by now. */
    fun endedItself(lastPositionMs: Long, durationMs: Long, elapsedMs: Long): Boolean =
        durationMs > 0 && lastPositionMs + elapsedMs >= durationMs - (END_SLACK_MS + elapsedMs / 20)

    private const val END_SLACK_MS = 1500L

    /** 0 to 1 over [share] 0 to 1; sin squared, so that the two ends are soft. */
    private fun curve(share: Float): Float = sin(PI / 2 * share).let { (it * it).toFloat() }
}
