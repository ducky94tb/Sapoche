package app.sapoche.core

/** Minimal track metadata, enough to display a result and put it on the queue. */
data class TrackInfo(
    val videoId: String,
    val title: String,
    val artist: String,
    val thumbUrl: String?,
    val durationSec: Long,
)

/** A playlist found by search, not yet opened. */
data class PlaylistRef(
    val id: String,
    val title: String,
    val uploader: String,
    val thumbUrl: String?,
    val songCount: Long,
)

/** A playlist's songs in order, without the unavailable ones. */
data class Playlist(val title: String, val tracks: List<TrackInfo>)

/** A resolved audio stream, with details used to judge quality. */
data class AudioSource(
    val url: String,
    val codec: String,
    val bitrateKbps: Int,
    val contentLength: Long,
    val itag: Int,
    /** How many dB the song is above YouTube's reference level (negative when below), when the answer says. */
    val loudnessDb: Double? = null,
    /** Sample rate in Hz (e.g. 48000, 44100), or 0 when the answer does not say. */
    val sampleRate: Int = 0,
)

/** What the player is actually decoding for the current song: codec name, average bitrate (kbps) and sample rate (Hz). */
data class AudioFormat(val codec: String, val kbps: Int = 0, val hz: Int = 0) {
    companion object {
        /** Codec name and sample rate for YouTube audio itags when the player has not reported them yet. */
        fun fromItag(itag: Int): Pair<String, Int>? = when (itag) {
            249, 250, 251, 774 -> "Opus" to 48_000
            140, 141 -> "AAC" to 44_100
            139 -> "AAC HE" to 22_050
            else -> null
        }

        /** Human-readable codec name from a MIME type and optional codec string / YouTube itag. */
        fun codecFromMime(mime: String?, codecs: String? = null, itag: Int? = null): String? {
            val lower = mime?.lowercase().orEmpty()
            val c = codecs?.lowercase().orEmpty()
            return when {
                lower == "audio/opus" || c.contains("opus") -> "Opus"
                lower == "audio/mp4a-latm" || lower == "audio/mp4" || lower == "audio/aac" || c.startsWith("mp4a") ->
                    if (itag == 139 || c.contains("mp4a.40.5") || c.contains("mp4a.40.29")) "AAC HE" else "AAC"
                lower == "audio/mpeg" || lower == "audio/mp3" -> "MP3"
                lower == "audio/flac" || lower == "audio/x-flac" -> "FLAC"
                lower == "audio/vorbis" -> "Vorbis"
                lower == "audio/alac" -> "ALAC"
                lower == "audio/raw" || lower == "audio/wav" || lower == "audio/x-wav" -> "PCM"
                lower == "audio/ac3" -> "AC-3"
                lower == "audio/eac3" || lower == "audio/eac3-joc" -> "E-AC-3"
                else -> null
            }
        }

        /** Average bitrate in kbps from total stream/file bytes and duration in ms; 0 when either is missing. */
        fun kbpsOf(contentLength: Long, durationMs: Long): Int =
            if (contentLength > 0 && durationMs > 0) ((contentLength * 8L + durationMs / 2) / durationMs).toInt() else 0
    }
}

/** A video-only stream, played together with an audio stream when the picture is wanted. */
data class VideoSource(
    val url: String,
    val height: Int,
    /** Container and codec as YouTube reports them, e.g. "MPEG_4" with "avc1.4d401f". */
    val format: String,
    val codec: String,
    val bitrateKbps: Int,
    val contentLength: Long,
    val itag: Int,
    val width: Int = 0,
    /** Frames per second; 0 when the answer does not say (30 is then assumed). */
    val fps: Int = 0,
    /** Where the header of the stream (`Initialization`) and its index of segments (`indexRange`) lie in it; null when not told. */
    val initRange: ByteRange? = null,
    val indexRange: ByteRange? = null,
)

/** Bytes [first] to [last], both included, as in an HTTP `Range` header. */
data class ByteRange(val first: Long, val last: Long)

data class Resolved(
    val track: TrackInfo,
    val best: AudioSource,
    val all: List<AudioSource>,
    val resolveMs: Long,
    /** Video-only streams found beside the audio, best first; empty when the video cannot be played. */
    val videos: List<VideoSource> = emptyList(),
    /** Which way the streams were found, for the log. */
    val via: String = "newpipe",
    /** How long the steps of the resolve took, for the log; empty when it is not told. */
    val steps: String = "",
)

/**
 * Swappable stream source: this device (NewPipeExtractor), a home host, iOS, etc.
 * The rest of the app only knows this interface.
 */
interface StreamResolver {
    /** Up to [limit] videos matching [query], over as many pages as it takes; with [songsOnly] only what YouTube Music lists as songs. */
    suspend fun search(query: String, limit: Int = 10, songsOnly: Boolean = false): List<TrackInfo>
    suspend fun resolve(videoId: String): Resolved

    /** Playlists matching [query]. */
    suspend fun searchPlaylists(query: String, limit: Int = 10): List<PlaylistRef>

    /** The first [limit] playable songs of the playlist with the given id. */
    suspend fun playlist(playlistId: String, limit: Int = 50): Playlist

    /** Videos YouTube lists beside the one with [videoId], in its order; live streams and lengthless ones left out. */
    suspend fun related(videoId: String, limit: Int = 25): List<TrackInfo>

    /** What YouTube would complete [query] to while it is being typed. */
    suspend fun suggest(query: String): List<String>
}
