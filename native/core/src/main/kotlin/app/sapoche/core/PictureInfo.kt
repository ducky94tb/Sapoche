package app.sapoche.core

/**
 * What the screen is told of the height of the picture that plays: the heights the song has that this phone can play, the
 * one playing, the tallest this phone plays at all, and why the picture is not as tall as asked (see [limit]). Mirrors
 * `PictureInfo` of Swift.
 */
data class PictureInfo(
    val heights: List<Int> = emptyList(),
    val now: Int = 0,
    val max: Int = VideoPicker.H264_MAX_HEIGHT,
    /** `metered` (mobile data), `network` (the link was too slow for more), `video` (the song has no taller one); null for none. */
    val limit: String? = null,
) {
    companion object {
        /** [asked] is the height the person chose, [max] the tallest this phone plays, [now] the height playing (0 when no picture plays). */
        fun of(heights: List<Int>, now: Int, asked: Int, max: Int, metered: Boolean, budgetKbps: Long): PictureInfo {
            if (now == 0 || heights.isEmpty()) return PictureInfo(heights, now, max)
            val wanted = minOf(asked, max)
            val allowed = if (metered) minOf(wanted, VideoPicker.H264_MAX_HEIGHT) else wanted
            val best = heights.lastOrNull { it <= allowed } ?: heights.first()
            val limit = when {
                metered && wanted > VideoPicker.H264_MAX_HEIGHT && now <= VideoPicker.H264_MAX_HEIGHT -> "metered"
                now < best && budgetKbps > 0 -> "network"
                now >= best && heights.last() < wanted -> "video"
                else -> null
            }
            return PictureInfo(heights, now, max, limit)
        }
    }
}
