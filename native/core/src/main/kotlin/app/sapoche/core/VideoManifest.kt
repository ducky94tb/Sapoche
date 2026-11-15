package app.sapoche.core

/**
 * The picture streams of a song as one DASH manifest (static, one period, one set of streams), so that the player holds every height of it
 * and changes from one to another without loading the song again. Nothing is fetched from this: each stream is one file
 * whose header and index of segments lie at known byte ranges (`Initialization`, `indexRange`), which is what the answer
 * of the `player` request gives.
 */
object VideoManifest {

    /**
     * The manifest of [sources] for a song of [durationMs]; the address of a stream in it is [addressOf]. A stream that
     * does not tell where its index is cannot be played this way and is left out. Null when none is left.
     */
    fun dash(sources: List<VideoSource>, durationMs: Long, addressOf: (VideoSource) -> String): String? {
        val usable = sources.filter { it.initRange != null && it.indexRange != null && it.height > 0 }
        if (usable.isEmpty()) return null
        return buildString {
            append("""<?xml version="1.0" encoding="utf-8"?>""").append('\n')
            append("""<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" minBufferTime="PT1.5S" """)
            append("""profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" mediaPresentationDuration="${duration(durationMs)}">""").append('\n')
            append("<Period>\n")
            // One set for every stream: the player then moves between them inside one stream of pictures, with no loading of the
            // song again, and the sets of the two containers are not a reason for it to start the picture over
            append("""<AdaptationSet contentType="video" segmentAlignment="true" subsegmentAlignment="true" subsegmentStartsWithSAP="1">""").append('\n')
            usable.sortedWith(compareBy({ it.height }, { it.bitrateKbps })).forEach { source ->
                append("""<Representation id="${source.itag}" mimeType="${mimeOf(source)}" codecs="${escape(source.codec)}" bandwidth="${maxOf(1, source.bitrateKbps) * 1000L}"""")
                if (source.width > 0) append(""" width="${source.width}"""")
                append(""" height="${source.height}"""")
                if (source.fps > 0) append(""" frameRate="${source.fps}"""")
                append(">\n")
                append("<BaseURL>${escape(addressOf(source))}</BaseURL>\n")
                val index = source.indexRange!!
                val init = source.initRange!!
                append("""<SegmentBase indexRange="${index.first}-${index.last}"><Initialization range="${init.first}-${init.last}"/></SegmentBase>""").append('\n')
                append("</Representation>\n")
            }
            append("</AdaptationSet>\n")
            append("</Period>\n</MPD>\n")
        }
    }

    private fun mimeOf(source: VideoSource) = if (source.format.equals("WEBM", ignoreCase = true)) "video/webm" else "video/mp4"

    /** An ISO 8601 duration with milliseconds, as `PT213.040S`. */
    private fun duration(ms: Long) = "PT${ms / 1000}.${(ms % 1000).toString().padStart(3, '0')}S"

    private fun escape(text: String) = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}
