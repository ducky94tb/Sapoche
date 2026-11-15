package app.sapoche

import android.content.Context
import android.util.Pair
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.Timeline
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.chunk.MediaChunk
import androidx.media3.exoplayer.source.chunk.MediaChunkIterator
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.trackselection.BaseTrackSelection
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.MappingTrackSelector
import androidx.media3.exoplayer.upstream.BandwidthMeter
import app.sapoche.core.VideoPicker
import app.sapoche.core.VideoSource

/**
 * Chooses which of the heights of a song's picture the player plays: the one [VideoPicker] gives for the ceiling and the
 * link, and never a change by itself (the player's own choice by its estimate of the link was seen to fall to 360p when the
 * link was fine, see `docs/systems/playback.md`).
 *
 * The change is made inside the stream, as the player's own adaptive choice makes it: all heights of a song are one set
 * of streams ([app.sapoche.core.VideoManifest]), so a new ceiling is put to use by the next piece of the picture that is
 * fetched, and what was fetched ahead of the old one is let go, with the sound going on. Only a change of codec (H.264
 * and VP9) has the decoder start again, which holds the picture for a moment.
 */
@UnstableApi
class PictureTrackSelector private constructor(context: Context, choice: PictureChoice) :
    DefaultTrackSelector(context, PictureSelections(choice)) {

    constructor(context: Context, ceiling: () -> Int, budgetKbps: () -> Long) : this(context, PictureChoice(ceiling, budgetKbps))

    override fun selectVideoTrack(
        mappedTrackInfo: MappingTrackSelector.MappedTrackInfo,
        rendererFormatSupports: Array<Array<IntArray>>,
        mixedMimeTypeSupports: IntArray,
        params: Parameters,
        selectedAudioLanguage: String?,
    ): Pair<ExoTrackSelection.Definition, Int>? {
        for (renderer in 0 until mappedTrackInfo.rendererCount) {
            if (mappedTrackInfo.getRendererType(renderer) != C.TRACK_TYPE_VIDEO) continue
            val groups = mappedTrackInfo.getTrackGroups(renderer)
            for (g in 0 until groups.length) {
                val group = groups[g]
                val playable = (0 until group.length).filter {
                    RendererCapabilities.getFormatSupport(rendererFormatSupports[renderer][g][it]) == C.FORMAT_HANDLED &&
                        PictureChoice.itagOf(group.getFormat(it)) != null
                }
                if (playable.isEmpty()) continue
                // Every height there is, for [PictureSelection] to move between; the number beside it is the renderer it is for
                return Pair(ExoTrackSelection.Definition(group, *playable.toIntArray()), renderer)
            }
        }
        // Not a picture of ours (a file with a video track of its own): as the player would
        return super.selectVideoTrack(mappedTrackInfo, rendererFormatSupports, mixedMimeTypeSupports, params, selectedAudioLanguage)
    }
}

/** Which stream of a song's picture is the one to play now. */
@UnstableApi
internal class PictureChoice(private val ceiling: () -> Int, private val budgetKbps: () -> Long) {

    /** The tallest to play now: what the person chose, as far as the phone, the network and the link allow. Cheap: asked about 100 times a second. */
    fun ceilingNow(): Int = VideoPicker.startCeiling(ceiling(), budgetKbps())

    /** What was chosen for a song's streams while the ceiling it was chosen for stands, as the link measures differently from one moment to the next. */
    private val chosen = object : LinkedHashMap<String, Pair<Int, Int>>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Pair<Int, Int>>) = size > 8
    }

    /** The itag to play among [streams] (all of one song), picked as [VideoPicker] does. */
    fun itag(key: String, streams: List<VideoSource>): Int {
        val ceilingNow = ceilingNow()
        return synchronized(chosen) {
            chosen[key]?.takeIf { it.first == ceilingNow }?.second
                ?: (VideoPicker.pick(streams, ceilingNow, budgetKbps())?.itag ?: streams.first().itag).also {
                    chosen[key] = Pair(ceilingNow, it)
                    EventLog.d("picture", "selected itag=$it of ${streams.size} (ceiling ${ceilingNow}p, budget ${budgetKbps()}kbps)")
                }
        }
    }

    companion object {
        /** The itag of a stream of the manifest. The player puts the number of the set before the id of the stream ("0:137"), and the merge of sources another. */
        fun itagOf(format: Format): Int? = format.id?.substringAfterLast(':')?.toIntOrNull()

        /** A stream as [VideoPicker] reads it; only what picking needs. */
        fun sourceOf(format: Format, itag: Int) = VideoSource(
            url = "", height = format.height, format = if (format.containerMimeType?.endsWith("webm") == true) "WEBM" else "MPEG_4",
            codec = format.codecs ?: "", bitrateKbps = format.bitrate / 1000, contentLength = -1, itag = itag,
        )
    }
}

/** Makes the selections of a song's picture, and leaves the sound's to the player's own. */
@UnstableApi
internal class PictureSelections(private val choice: PictureChoice) : ExoTrackSelection.Factory {
    private val own = AdaptiveTrackSelection.Factory()

    override fun createTrackSelections(
        definitions: Array<ExoTrackSelection.Definition?>,
        bandwidthMeter: BandwidthMeter,
        mediaPeriodId: MediaSource.MediaPeriodId,
        timeline: Timeline,
    ): Array<ExoTrackSelection?> = Array(definitions.size) { i ->
        val definition = definitions[i] ?: return@Array null
        val ours = definition.tracks.size > 1 && definition.tracks.all { PictureChoice.itagOf(definition.group.getFormat(it)) != null } &&
            definition.group.getFormat(definition.tracks[0]).sampleMimeType?.startsWith("video/") == true
        if (ours) PictureSelection(definition.group, definition.tracks, choice)
        else own.createTrackSelections(arrayOf(definition), bandwidthMeter, mediaPeriodId, timeline)[0]
    }
}

/** The one stream of a song's picture that plays now, changed to another when the ceiling or the link says so (see [PictureTrackSelector]). */
@UnstableApi
internal class PictureSelection(group: TrackGroup, tracks: IntArray, private val choice: PictureChoice) : BaseTrackSelection(group, *tracks) {

    private val streams = List(length) { PictureChoice.sourceOf(getFormat(it), PictureChoice.itagOf(getFormat(it))!!) }
    private val key = streams.joinToString(",") { it.itag.toString() }
    private var ceilingChosenFor = choice.ceilingNow()
    private var selected = indexOfChosen()

    private fun indexOfChosen(): Int {
        val itag = choice.itag(key, streams)
        return streams.indexOfFirst { it.itag == itag }.coerceAtLeast(0)
    }

    /** The player asks about every ten milliseconds or so: the choice is made again only when the ceiling it depends on has changed. */
    private fun refresh() {
        val ceilingNow = choice.ceilingNow()
        if (ceilingNow == ceilingChosenFor) return
        ceilingChosenFor = ceilingNow
        selected = indexOfChosen()
    }

    override fun getSelectedIndex() = selected

    override fun getSelectionReason() = C.SELECTION_REASON_ADAPTIVE

    override fun getSelectionData(): Any? = null

    override fun updateSelectedTrack(
        playbackPositionUs: Long,
        bufferedDurationUs: Long,
        availableDurationUs: Long,
        queue: List<MediaChunk>,
        mediaChunkIterators: Array<MediaChunkIterator>,
    ) = refresh()

    /**
     * What is fetched ahead in another height than the one chosen now is let go, but for the next moments, so that the
     * picture does not stop for the piece that is being shown: from then on the new height is fetched.
     */
    override fun evaluateQueueSize(playbackPositionUs: Long, queue: List<MediaChunk>): Int {
        refresh()
        val wanted = streams[selected].itag
        for (i in queue.indices) {
            val chunk = queue[i]
            // By the itag: the id of the format of a chunk ("137") is not the id of the track of the set ("0:137", the merge puts its
            // number before it), and told apart by the whole id every chunk is of another height, and is let go and fetched again for ever
            if (chunk.startTimeUs - playbackPositionUs >= KEEP_US && PictureChoice.itagOf(chunk.trackFormat) != wanted) return i
        }
        return queue.size
    }

    private companion object {
        /** The picture that is this close to being shown is kept whatever its height. */
        const val KEEP_US = 1_500_000L
    }
}
