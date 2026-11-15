package app.sapoche

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import app.sapoche.core.VideoPicker
import app.sapoche.core.VideoSource

/**
 * What this phone plays of the picture of a song. H.264 up to 1080p is played by every phone in hardware. Above that
 * YouTube only has VP9, which is taken when the phone has a decoder for it that is hardware, and that takes the size
 * and the rate of the stream: VP9 decoded by the processor makes a phone hot (see `docs/systems/playback.md`).
 */
object PictureDecoders {
    private const val VP9 = "video/x-vnd.on2.vp9"

    /** The hardware VP9 decoders of the phone: what the system lists is looked at once, as it takes a moment. */
    private val vp9: List<MediaCodecInfo.VideoCapabilities> by lazy {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && VP9 in it.supportedTypes && isHardware(it) }
            .mapNotNull { it.getCapabilitiesForType(VP9).videoCapabilities }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated && !info.isSoftwareOnly
        else !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.") && !info.name.startsWith("c2.google.")

    /** Whether the phone plays [source]: H.264 always, VP9 when a hardware decoder takes its size and rate. */
    fun decodable(source: VideoSource): Boolean = when {
        source.format.equals("MPEG_4", ignoreCase = true) && source.codec.startsWith("avc1") -> true
        // YouTube writes the codec "vp9", or "vp09.00.40.08" with its profile and level
        source.format.equals("WEBM", ignoreCase = true) && (source.codec == "vp9" || source.codec.startsWith("vp09")) -> vp9Plays(source)
        else -> false
    }

    private fun vp9Plays(source: VideoSource): Boolean {
        val width = if (source.width > 0) source.width else source.height * 16 / 9
        val rate = if (source.fps > 0) source.fps else 30
        return vp9.any { it.areSizeAndRateSupported(width, source.height, rate.toDouble()) }
    }

    /** The tallest picture this phone plays, at 30 frames per second; 1080 when it has no hardware VP9 decoder that takes more. */
    val maxHeight: Int by lazy {
        listOf(2160 to 3840, 1440 to 2560).firstOrNull { (height, width) -> vp9.any { it.areSizeAndRateSupported(width, height, 30.0) } }?.first
            ?: VideoPicker.H264_MAX_HEIGHT
    }
}
