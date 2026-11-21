package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class ProtocolTasteTest {
    private fun parse(text: String) = Json.parseToJsonElement(text).jsonObject

    @Test
    fun `an offer is sent as songs, a sealed one as the envelope, and taking it back as null`() {
        val plain = parse(Protocol.tasteSet(listOf(TasteSeed("bNp9pn0ni3I", "Song", "Artist"))))
        assertEquals("taste.set", plain.getValue("t").jsonPrimitive.content)
        assertEquals("bNp9pn0ni3I", plain.getValue("seeds").jsonArray.single().jsonObject.getValue("v").jsonPrimitive.content)
        assertEquals(JsonNull, parse(Protocol.tasteSet(null)).getValue("seeds"))
        val sealed = parse(Protocol.tasteSetSealed("AQE-abc"))
        assertEquals("AQE-abc", sealed.getValue("s").jsonPrimitive.content)
        assertTrue("seeds" !in sealed)
        assertEquals(JsonNull, parse(Protocol.tasteSetSealed(null)).getValue("s"))
    }

    @Test
    fun `the songs the others offered come with the request for more songs, and an older server sends none`() {
        val ask = Protocol.parse(
            """{"t":"autoplay.fill","epoch":4,"videoId":"bNp9pn0ni3I","title":"One","tastes":[{"by":"m1","seeds":[{"v":"UoXllQoqEBY","ti":"Two","ar":"x"}]},{"by":"m2","s":"AQE-sealed"}]}""",
        ) as ServerMessage.AutoplayFill
        assertEquals(listOf("m1", "m2"), ask.tastes.map { it.by })
        assertEquals("UoXllQoqEBY", ask.tastes[0].seeds?.single()?.v)
        assertEquals("AQE-sealed", ask.tastes[1].s)
        assertNull(ask.tastes[1].seeds)
        val old = Protocol.parse("""{"t":"autoplay.fill","epoch":4,"videoId":"bNp9pn0ni3I","title":"One"}""") as ServerMessage.AutoplayFill
        assertTrue(old.tastes.isEmpty())
    }

    @Test
    fun `explicit and year travel in queue messages and default when omitted`() {
        val add = parse(Protocol.queueAdd("bNp9pn0ni3I", "Song", "Artist", null, 180_000, explicit = true, year = "2017"))
        assertEquals("true", add.getValue("explicit").jsonPrimitive.content)
        assertEquals("2017", add.getValue("year").jsonPrimitive.content)
        val plain = parse(Protocol.queueAdd("bNp9pn0ni3I", "Song", "Artist", null, 180_000))
        assertTrue("explicit" !in plain && "year" !in plain)

        val many = parse(Protocol.queueAddMany(listOf(TrackRef("bNp9pn0ni3I", "Song", "Artist", null, 180_000, explicit = true, year = "2019"))))
        val first = many.getValue("tracks").jsonArray.single().jsonObject
        assertEquals("true", first.getValue("explicit").jsonPrimitive.content)
        assertEquals("2019", first.getValue("year").jsonPrimitive.content)

        val prep = Protocol.parse(
            """{"t":"prepare","epoch":1,"index":0,"seekToMs":0,"item":{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"Artist","durMs":180000,"addedBy":"u1","explicit":true,"year":"2017"}}""",
        ) as ServerMessage.Prepare
        assertTrue(prep.item.explicit)
        assertEquals("2017", prep.item.year)

        val oldPrep = Protocol.parse(
            """{"t":"prepare","epoch":1,"index":0,"seekToMs":0,"item":{"id":"q1","videoId":"bNp9pn0ni3I","title":"Song","artist":"Artist","durMs":180000,"addedBy":"u1"}}""",
        ) as ServerMessage.Prepare
        assertEquals(false, oldPrep.item.explicit)
        assertNull(oldPrep.item.year)
    }
}
