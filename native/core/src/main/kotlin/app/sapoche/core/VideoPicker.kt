package app.sapoche.core

/** Chooses which video-only stream to play beside the audio. */
object VideoPicker {

    /** What the sound that plays beside the picture takes, off the share of the link the picture may have. */
    private const val SOUND_KBPS = 160L

    /**
     * What the picture may take, in kbps, of a link that [bandwidthKbps] was measured to carry: two thirds of it, as the
     * audio's steps keep room to spare, less what the sound takes. 0 means no limit (nothing was measured); on a [weak]
     * network with nothing measured it is 1, which picks the least demanding picture there is.
     */
    fun budgetKbps(bandwidthKbps: Long, weak: Boolean): Long {
        if (bandwidthKbps <= 0) return if (weak) 1 else 0
        return maxOf(1L, bandwidthKbps * 2 / 3 - SOUND_KBPS)
    }

    /** The tallest the picture is taken from H.264, which every phone decodes in hardware; above it only VP9 is offered. */
    const val H264_MAX_HEIGHT = 1080

    /**
     * The tallest the picture may be at the start of a song: a ceiling above [H264_MAX_HEIGHT] is only used once the link
     * was measured, as nothing says yet that it carries a 1440p or 2160p stream (10 to 27 Mbps); the person can still ask
     * for more at once, and then it is [pick] that decides.
     */
    fun startCeiling(maxHeight: Int, budgetKbps: Long): Int =
        if (budgetKbps <= 0 && maxHeight > H264_MAX_HEIGHT) H264_MAX_HEIGHT else maxHeight

    /**
     * The tallest stream that fits within [maxHeight] and, when [budgetKbps] is above 0, takes no more than it. H.264
     * in MP4 comes first up to 1080p, because every phone decodes it in hardware and another codec may be decoded by
     * the processor, which is what makes a phone hot: a taller picture of another codec is taken only when no H.264 one
     * fits. Above 1080p there is only VP9, which is taken when the phone [decodable] says it plays it (in hardware, see
     * the app) and the budget allows; else what [maxHeight] of 1080 would have given. At the height chosen the one with
     * most bitrate that still fits. When nothing fits (the video has only larger streams, or only dearer ones) the
     * smallest available one is used rather than none at all. HDR streams are never taken: the picture is drawn as SDR.
     */
    fun pick(
        sources: List<VideoSource>,
        maxHeight: Int,
        budgetKbps: Long = 0,
        decodable: (VideoSource) -> Boolean = { true },
    ): VideoSource? {
        val usable = sources.filter { !it.isHdr && decodable(it) }
        if (usable.isEmpty()) return null
        fun fits(source: VideoSource, limit: Int) = source.height <= limit && (budgetKbps <= 0 || source.bitrateKbps <= budgetKbps)
        if (maxHeight > H264_MAX_HEIGHT) {
            val taller = usable.filter { it.height > H264_MAX_HEIGHT && fits(it, maxHeight) }
            taller.maxOfOrNull { it.height }?.let { height ->
                return taller.filter { it.height == height }.maxByOrNull { it.bitrateKbps }
            }
        }
        val limit = minOf(maxHeight, H264_MAX_HEIGHT)
        val fitting = usable.filter { fits(it, limit) }
        if (fitting.isEmpty()) return usable.minWithOrNull(compareBy({ it.height }, { it.bitrateKbps }))
        val pool = fitting.filter { it.isH264 }.ifEmpty { fitting }
        val tallest = pool.maxOf { it.height }
        return pool.filter { it.height == tallest }.maxByOrNull { it.bitrateKbps }
    }

    /** The streams that go into the manifest of a song: all the picture can be played from on this phone. */
    fun playable(sources: List<VideoSource>, decodable: (VideoSource) -> Boolean): List<VideoSource> =
        sources.filter { !it.isHdr && decodable(it) }

    /** The heights of [sources] that can be chosen, lowest first. */
    fun heights(sources: List<VideoSource>): List<Int> = sources.map { it.height }.distinct().sorted()

    /** HDR (VP9 profile 2, 10 bits) has the picture draw in the wrong colours: Flutter's texture is SDR. */
    private val VideoSource.isHdr: Boolean
        get() = codec.startsWith("vp09.02") || codec.startsWith("vp9.2")

    private val VideoSource.isH264: Boolean
        get() = format.equals("MPEG_4", ignoreCase = true) && codec.startsWith("avc1")
}
