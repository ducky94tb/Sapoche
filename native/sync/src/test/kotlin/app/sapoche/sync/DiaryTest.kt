package app.sapoche.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiaryTest {
    private val fixture = Json.parseToJsonElement(
        DiaryTest::class.java.getResourceAsStream("/diary_levels.json")!!.bufferedReader().readText(),
    ).jsonObject

    private fun rows(name: String) = fixture.getValue(name).jsonArray.map { it as JsonObject }

    @Test
    fun levelsAreInferredAsTheSharedFixtureSays() {
        for (row in rows("levels")) {
            val tag = row.getValue("tag").jsonPrimitive.content
            val message = row.getValue("message").jsonPrimitive.content
            assertEquals(row.getValue("level").jsonPrimitive.content[0], Diary.infer(tag, message).letter, "[$tag] $message")
        }
    }

    @Test
    fun theLevelIsReadBackFromALine() {
        for (row in rows("lines")) {
            val line = row.getValue("line").jsonPrimitive.content
            val letter = row.getValue("level").jsonPrimitive.content.takeIf { it != "null" }?.get(0)
            assertEquals(letter, Diary.levelOf(line)?.letter, line)
        }
    }

    @Test
    fun aLineIsBuiltInTheSharedShape() {
        assertEquals("11-23 14:02:11.123 W [room] closed: 1006", Diary.line("11-23 14:02:11.123", LogLevel.WARN, "room", "closed: 1006"))
    }

    private fun tmp() = java.nio.file.Files.createTempDirectory("diary").toFile()
    private fun line(i: Int, level: LogLevel) = Diary.line("11-23 14:02:%02d.000".format(i % 60), level, "t", "n$i " + "x".repeat(40))

    @Test
    fun noiseNeverPushesKeyLinesOutOfReach() {
        val files = DiaryFiles(tmp(), maxBytes = 2_000, maxKeyBytes = 10_000)
        files.append(listOf(line(1, LogLevel.ERROR), line(2, LogLevel.MAIN)))
        for (i in 10 until 400) files.append(listOf(line(i, LogLevel.DETAIL)))
        val all = files.readAll()
        assertTrue(all.any { it.contains("n1 ") }, "the error is still there")
        assertTrue(all.any { it.contains("n2 ") }, "the main line is still there")
        assertTrue(all.size < 120, "the noise of the early part is gone: ${all.size}")
        assertTrue(all.last().contains("n399 "))
        assertEquals(all.size, all.toSet().size, "a key line that the full files still hold is listed once")
    }

    @Test
    fun theFullFilesTurnOverWhenFull() {
        val dir = tmp()
        val files = DiaryFiles(dir, maxBytes = 1_000, maxKeyBytes = 10_000)
        for (i in 1..100) files.append(listOf(line(i, LogLevel.INFO)))
        assertTrue(File(dir, "sapoche.log").length() <= 1_000)
        assertTrue(File(dir, "sapoche.1.log").exists())
        val all = files.readAll()
        assertTrue(all.last().contains("n100 "))
        assertTrue(all.size in 15..40, "about two files of lines: ${all.size}")
        assertEquals(all.size, all.map { it.substringAfter("n").substringBefore(' ').toInt() }.distinct().size)
    }

    @Test
    fun theKeyFileKeepsTheNewerHalfWhenFull() {
        val dir = tmp()
        val files = DiaryFiles(dir, maxBytes = 1_000_000, maxKeyBytes = 1_000)
        for (i in 1..60) files.append(listOf(line(i, LogLevel.WARN)))
        File(dir, "sapoche.log").delete() // only the key file is left to read
        val keys = files.readAll()
        assertTrue(keys.last().contains("n60 "))
        assertTrue(keys.size in 5..30, "the newer part: ${keys.size}")
        assertTrue(File(dir, "sapoche-key.log").length() <= 1_000 + 70)
    }

    @Test
    fun clearingRemovesEverything() {
        val files = DiaryFiles(tmp())
        files.append(listOf(line(1, LogLevel.ERROR)))
        files.clear()
        assertEquals(emptyList(), files.readAll())
    }

    @Test
    fun aFileOfTheOldShapeIsDropped() {
        val dir = tmp()
        File(dir, "sapoche.log").writeText("01:00:00.000 [log] old\n")
        assertEquals(emptyList(), DiaryFiles(dir).readAll())
    }
}
