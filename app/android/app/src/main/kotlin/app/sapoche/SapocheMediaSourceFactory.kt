package app.sapoche

import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy

/**
 * Builds the media source for a queue item. A plain item is just its audio stream; one marked with
 * [VIDEO_FRAGMENT] also gets the picture, played in step with the audio. The picture is a DASH manifest that the data
 * source makes up on the phone ([MANIFEST_SCHEME]), holding every height of it, so that the player changes from one to
 * another without loading the song again (see `PictureTrackSelector`).
 *
 * All parts are loaded through "sapoche:" style addresses that the data source turns into real URLs
 * when the loader opens them, so nothing here needs the network.
 */
class SapocheMediaSourceFactory(
    private val delegate: MediaSource.Factory,
    private val dash: MediaSource.Factory,
) : MediaSource.Factory {

    override fun setDrmSessionManagerProvider(provider: DrmSessionManagerProvider): MediaSource.Factory = apply {
        delegate.setDrmSessionManagerProvider(provider)
        dash.setDrmSessionManagerProvider(provider)
    }

    override fun setLoadErrorHandlingPolicy(policy: LoadErrorHandlingPolicy): MediaSource.Factory = apply {
        delegate.setLoadErrorHandlingPolicy(policy)
        dash.setLoadErrorHandlingPolicy(policy)
    }

    override fun getSupportedTypes(): IntArray = delegate.supportedTypes

    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val audio = delegate.createMediaSource(mediaItem)
        if (!isVideo(mediaItem)) return audio
        val picture = mediaItem.buildUpon().setUri("$MANIFEST_SCHEME:${mediaItem.mediaId}").setMimeType(MimeTypes.APPLICATION_MPD).build()
        return MergingMediaSource(dash.createMediaSource(picture), audio)
    }

    companion object {
        const val AUDIO_SCHEME = "sapoche"
        /** One picture stream of a song: "sapochev:<videoId>/<itag>". */
        const val VIDEO_SCHEME = "sapochev"

        /** The manifest of the picture of a song: "sapochd:<videoId>". */
        const val MANIFEST_SCHEME = "sapochd"
        const val VIDEO_FRAGMENT = "video"

        fun isVideo(item: MediaItem): Boolean = item.localConfiguration?.uri?.fragment == VIDEO_FRAGMENT

        fun uri(videoId: String, withVideo: Boolean): String =
            if (withVideo) "$AUDIO_SCHEME:$videoId#$VIDEO_FRAGMENT" else "$AUDIO_SCHEME:$videoId"
    }
}
