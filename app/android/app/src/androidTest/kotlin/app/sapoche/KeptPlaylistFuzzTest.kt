package app.sapoche

import androidx.test.core.app.ApplicationProvider
import app.sapoche.sync.TrackRef
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.Random

/**
 * Random sequences of everything a person can do to playlists, folders, likes and downloads, with the rules of kept playlists
 * checked from outside after every step (the oracle is worked out from the public lists, not from the SQL).
 */
class KeptPlaylistFuzzTest {

    private lateinit var store: LibraryStore

    @Before
    fun open() {
        store = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
    }

    @After
    fun close() = store.close()

    private fun song(n: Int) = TrackRef("v$n", "Title $n", "Artist", null, 200_000)

    private suspend fun kept(): Set<String> {
        val folders = store.folders().associate { it.id to it.offline }
        val songs = HashSet<String>()
        for (list in store.playlists()) {
            if (list.offline || (list.folderId?.let { folders[it] } == true)) songs += store.playlistTracks(list.id).map { it.videoId }
        }
        return songs
    }

    private suspend fun states() = store.downloads().associate { it.track.videoId to it.state }

    private suspend fun check(seed: Long, log: List<String>) {
        val keptSongs = kept()
        val listed = states()
        val orphans = listed.filter { it.value == LibraryStore.WAITING && it.key !in keptSongs }.keys.sorted()
        assertEquals("waiting with nothing asking for it; seed $seed; steps: ${log.takeLast(6)}", emptyList<String>(), orphans)
        val toFetch = store.offlineToDownload().map { it.videoId }.toSet()
        assertTrue("a song that is not kept would be fetched; seed $seed", keptSongs.containsAll(toFetch))
        assertTrue("a song already listed would be asked again; seed $seed", toFetch.none { it in listed })
        val keptFolders = store.folders().filter { it.offline }.map { it.id }.toSet()
        val any = store.playlists().any { it.offline || (it.folderId in keptFolders) }
        assertEquals("hasOffline; seed $seed", any, store.hasOffline())
        store.nextDownload(LibraryStore.WAITING, keptOnly = true)?.let { assertTrue("a run for kept playlists took $it; seed $seed", it in keptSongs) }
    }

    @Test
    fun randomThingsDoneToKeptPlaylistsNeverLeaveWhatNobodyAsksFor() = runTest {
        for (seed in 1L..60L) {
            store.close()
            store = LibraryStore(ApplicationProvider.getApplicationContext(), name = null)
            val rng = Random(seed)
            val log = ArrayList<String>()
            repeat(80) {
                val lists = store.playlists()
                val folders = store.folders()
                when (rng.nextInt(15)) {
                    0 -> {
                        val n = rng.nextInt(6)
                        store.createPlaylist("P", List(n) { song(rng.nextInt(14)) })
                        log += "create $n"
                    }
                    1 -> lists.randomOrNull(rng)?.let {
                        store.addToPlaylist(it.id, List(1 + rng.nextInt(3)) { song(rng.nextInt(14)) })
                        log += "add ${it.id}"
                    }
                    2 -> lists.randomOrNull(rng)?.let { list ->
                        store.playlistTracks(list.id).randomOrNull(rng)?.let {
                            store.removeFromPlaylist(list.id, it.videoId)
                            log += "remove ${it.videoId} from ${list.id}"
                        }
                    }
                    3 -> lists.randomOrNull(rng)?.let { store.deletePlaylist(it.id); log += "delete ${it.id}" }
                    4 -> { store.createFolder("F"); log += "folder" }
                    5 -> folders.randomOrNull(rng)?.let { store.deleteFolder(it.id); log += "delete folder ${it.id}" }
                    6 -> lists.randomOrNull(rng)?.let {
                        val folder = if (rng.nextInt(100) < 25) null else folders.randomOrNull(rng)?.id
                        store.setPlaylistFolder(it.id, folder)
                        log += "move ${it.id} to $folder"
                    }
                    7, 8 -> lists.randomOrNull(rng)?.let {
                        val on = rng.nextInt(100) < 60
                        val remove = rng.nextInt(100) < 40
                        val expected = store.offlineRemovable(it.id, null, keepLiked = false)
                        val before = states().count { s -> s.value == LibraryStore.DONE }
                        val mine = store.playlistTracks(it.id).map { t -> t.videoId }
                        val dropped = store.setPlaylistOffline(it.id, on, remove)
                        val after = states().count { s -> s.value == LibraryStore.DONE }
                        if (!on) {
                            val keptNow = kept()
                            val still = states().filter { s -> s.key in mine && s.key !in keptNow && (s.value == LibraryStore.WAITING || s.value == LibraryStore.QUEUED) }.keys.sorted()
                            assertEquals("stopping must stop what is still to come; seed $seed", emptyList<String>(), still)
                        }
                        if (!on && remove) assertEquals("the question said $expected; seed $seed", expected, before - after)
                        if (on) assertEquals(emptyList<String>(), dropped)
                        log += "playlist ${it.id} ${if (on) "on" else "off"}${if (remove) " remove" else ""}"
                    }
                    9 -> folders.randomOrNull(rng)?.let {
                        val on = rng.nextInt(100) < 60
                        val remove = rng.nextInt(100) < 40
                        val expected = store.offlineRemovable(null, it.id, keepLiked = false)
                        val before = states().count { s -> s.value == LibraryStore.DONE }
                        store.setFolderOffline(it.id, on, remove)
                        val after = states().count { s -> s.value == LibraryStore.DONE }
                        if (!on && remove) assertEquals("the question said $expected; seed $seed", expected, before - after)
                        log += "folder ${it.id} ${if (on) "on" else "off"}${if (remove) " remove" else ""}"
                    }
                    10 -> { val id = song(rng.nextInt(14)); store.setLiked(id, rng.nextInt(100) < 60); log += "like ${id.videoId}" }
                    11 -> { store.requestDownloads(store.offlineToDownload(), waiting = true); log += "job asks" }
                    12 -> store.nextDownload(LibraryStore.WAITING, keptOnly = true)?.let { store.finishDownload(it, 1); log += "fetched $it" }
                    13 -> states().keys.toList().randomOrNull(rng)?.let { store.removeDownload(it); log += "remove download $it" }
                    else -> if (rng.nextInt(100) < 10) {
                        store.clearDownloads()
                        assertTrue("after Delete all nothing is kept; seed $seed", !store.hasOffline())
                        log += "delete all"
                    } else {
                        val id = song(rng.nextInt(14))
                        store.requestDownloads(listOf(id))
                        // Half of what is asked for by hand is not fetched yet
                        if (rng.nextInt(100) < 50) store.finishDownload(id.videoId, 1)
                        log += "by hand ${id.videoId}"
                    }
                }
                check(seed, log)
            }
        }
    }

    /** The worst case the plan names: a folder of three full playlists must be kept, fetched in order and let go in seconds. */
    @Test
    fun aFolderOfThreeFullPlaylistsIsKeptAndLetGoInTime() = runTest {
        val folder = store.createFolder("Trips")
        for (list in 0 until 3) {
            val id = store.createPlaylist("P$list", List(500) { song(list * 500 + it) })
            store.setPlaylistFolder(id, folder)
        }
        val start = System.currentTimeMillis()
        store.setFolderOffline(folder, true)
        val wanted = store.offlineToDownload()
        assertEquals(1500, wanted.size)
        store.requestDownloads(wanted, waiting = true)
        var taken = 0
        while (true) {
            val id = store.nextDownload(LibraryStore.WAITING, keptOnly = true) ?: break
            store.pendingDownloads(LibraryStore.WAITING, keptOnly = true)
            store.finishDownload(id, 1)
            taken++
        }
        assertEquals(1500, taken)
        assertEquals(1500, store.offlineRemovable(null, folder, keepLiked = false))
        assertEquals(1500, store.setFolderOffline(folder, false, remove = true).size)
        assertEquals(0, store.downloads().size)
        val seconds = (System.currentTimeMillis() - start) / 1000.0
        android.util.Log.i("KeptFuzz", "1500 songs kept, fetched in order and let go: $seconds s")
        assertTrue("took $seconds s", seconds < 20)
    }

    private fun <T> List<T>.randomOrNull(rng: Random): T? = if (isEmpty()) null else this[rng.nextInt(size)]
}
