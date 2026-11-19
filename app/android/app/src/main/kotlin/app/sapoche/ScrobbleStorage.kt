package app.sapoche

import android.content.Context
import app.sapoche.sync.ScrobbleStorage
import java.io.File

/**
 * Where the scrobbler keeps what it needs: the token in a preferences file of its own and the queue in a file next to the
 * library. Both are in the app's private storage, which is not backed up (`allowBackup` is off), and neither is read by the
 * library backup or the diagnostic report.
 */
class AndroidScrobbleStorage(context: Context) : ScrobbleStorage {
    private val prefs = context.getSharedPreferences("scrobble", Context.MODE_PRIVATE)
    private val file = File(context.filesDir, "scrobble.json")

    override var token: String?
        get() = prefs.getString(TOKEN, null)
        set(value) = prefs.edit().apply { if (value == null) remove(TOKEN) else putString(TOKEN, value) }.apply()

    override fun loadState(): String? = runCatching { file.takeIf { it.exists() }?.readText() }.getOrNull()

    override fun saveState(text: String) {
        // Written whole beside it and moved over, so a phone that dies half way keeps the last good queue
        val tmp = File(file.parentFile, "scrobble.json.tmp")
        runCatching {
            tmp.writeText(text)
            if (!tmp.renameTo(file)) file.writeText(text)
        }
    }

    private companion object {
        const val TOKEN = "listenbrainz_token"
    }
}
