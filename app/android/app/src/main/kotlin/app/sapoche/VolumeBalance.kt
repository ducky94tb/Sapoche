package app.sapoche

import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.PlayerMessage
import androidx.media3.exoplayer.Renderer
import app.sapoche.core.Crossfade
import app.sapoche.core.Loudness
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The player's volume: the song's own factor (see [Loudness]) times the fade of the sleep timer times the soft change
 * between songs (see [Crossfade]), all of which only ever turn the volume down. Everything but [BookListener] runs on the main thread, where ExoPlayer is used.
 *
 * A song that follows the one playing is turned to its own level by a message to the audio renderer at the very start of
 * that song, which the playing thread delivers: setting the volume when the main thread hears of the change would be a
 * few tens of milliseconds late, and the start of a loud song could be heard at the old level.
 */
class VolumeBalance(
    private val exo: ExoPlayer,
    private val book: LoudnessBook,
    private val scope: CoroutineScope,
    /** Whether songs are to be evened out; the person's choice. */
    private val on: () -> Boolean,
    /** The seconds of the soft change between songs, 0 for none; the person's choice. */
    private val crossfade: () -> Int,
    /** The picture is on screen: a sound cut in the middle of a scene would sound odd, so songs change as they are. */
    private val pictureShown: () -> Boolean,
) {
    private var fade = 1f

    /** The song that plays came by itself, so it fades in; one that was chosen starts as it is. */
    private var startedByItself = false
    private var ramping = false
    private val tick = Runnable { updateVolume() }
    private var queuedMessage: PlayerMessage? = null
    private val looked = HashSet<String>()
    private val main = Handler(Looper.getMainLooper())

    init {
        exo.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: androidx.media3.common.MediaItem?, reason: Int) {
                startedByItself = reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO
                apply()
            }

            override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) = apply()

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                // Only a move by the person (or the room's correction) inside the song: what comes by itself is told by the transition
                if (reason == Player.DISCONTINUITY_REASON_SEEK || reason == Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT) {
                    startedByItself = false
                    updateVolume()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) = updateVolume()
        })
        book.onHeard = { id -> main.post { heard(id) } }
    }

    /** The sleep timer's fade: the share (1 is full) of the volume that the loudness of the song allows. */
    fun fade(share: Float) {
        fade = share
        apply()
    }

    /** The choice to even songs out, or the seconds of the soft change, was changed. */
    fun changed() = apply()

    private fun heard(videoId: String) {
        val here = exo.currentMediaItem?.mediaId
        if (videoId == here || videoId == exo.nextMediaId()) apply()
    }

    private fun apply() {
        updateVolume()
        scheduleNext()
    }

    private fun updateVolume() {
        val id = exo.currentMediaItem?.mediaId
        val ramp = ramp()
        val volume = fade * ramp * factor(id)
        if ((ramp < 1f) != ramping) {
            ramping = ramp < 1f
            EventLog.d("volume", "$id soft change ${if (ramping) "begins" else "is over"} at ${exo.currentPosition} ms")
        }
        if (!ramping && volume != exo.volume) EventLog.d("volume", "$id volume=$volume (fade=$fade)")
        exo.volume = volume
        scheduleTick()
    }

    /** The share of the volume the soft change allows at the position of the song that plays. */
    private fun ramp(): Float {
        val seconds = crossfade()
        if (seconds <= 0 || pictureShown()) return 1f
        return Crossfade.ramp(exo.currentPosition, durationMs(), seconds, startedByItself, exo.hasNextMediaItem())
    }

    private fun durationMs(): Long =
        exo.duration.takeIf { it != C.TIME_UNSET } ?: exo.mediaMetadata.durationMs ?: 0L

    /**
     * Runs the clock only while a soft change is on: 30 times a second inside it, and once at the moment the end of the
     * song gets to it. Outside, nothing runs, so the phone sleeps as it did.
     */
    private fun scheduleTick() {
        main.removeCallbacks(tick)
        val seconds = crossfade()
        if (seconds <= 0 || !exo.isPlaying || pictureShown()) return
        val duration = durationMs()
        if (!Crossfade.applies(duration, seconds)) return
        val position = exo.currentPosition
        val outAt = duration - seconds * 1000L
        val delay = when {
            startedByItself && position < seconds * 500L -> TICK_MS
            !exo.hasNextMediaItem() -> return
            position >= outAt -> TICK_MS
            else -> ((outAt - position) / exo.playbackParameters.speed.coerceAtLeast(0.1f)).toLong().coerceAtLeast(1L)
        }
        main.postDelayed(tick, delay)
    }

    /** The factor of [videoId], 1 until its loudness is known; the library is asked once if this run has not heard it yet. */
    private fun factor(videoId: String?): Float {
        if (videoId == null || !on()) return 1f
        val db = book.of(videoId)
        if (db == null && looked.add(videoId)) {
            scope.launch { book.stored(videoId)?.let { book.onHeard(videoId) } }
        }
        return Loudness.gain(db)
    }

    /** The song behind the current one gets its volume at its first moment, see the class comment. */
    private fun scheduleNext() {
        queuedMessage?.cancel()
        queuedMessage = null
        val next = exo.currentMediaItemIndex + 1
        if (next >= exo.mediaItemCount) return
        val renderer = (0 until exo.rendererCount).firstOrNull { exo.getRendererType(it) == C.TRACK_TYPE_AUDIO }
            ?.let(exo::getRenderer) ?: return
        val item = exo.getMediaItemAt(next)
        // A song that comes by itself starts silent when it is to fade in; if it was chosen instead, the move takes it to full volume at once
        val start = crossfade().takeIf { it > 0 && !pictureShown() }
            ?.let { Crossfade.ramp(0, item.mediaMetadata.durationMs ?: 0L, it, fadeIn = true, fadeOut = false) } ?: 1f
        val volume = fade * start * factor(item.mediaId)
        EventLog.d("volume", "${item.mediaId} is to start at volume=$volume")
        queuedMessage = exo.createMessage(renderer)
            .setType(Renderer.MSG_SET_VOLUME)
            .setPayload(volume)
            .setPosition(next, 0)
            .setDeleteAfterDelivery(true)
            .send()
    }

    private companion object {
        const val TICK_MS = 33L
    }

    private fun ExoPlayer.nextMediaId(): String? =
        currentMediaItemIndex.plus(1).takeIf { it < mediaItemCount }?.let { getMediaItemAt(it).mediaId }
}
